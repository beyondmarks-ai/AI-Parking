import asyncio
from datetime import datetime, timedelta, timezone
from io import BytesIO
import json
import os
from pathlib import Path
from unittest import IsolatedAsyncioTestCase, skipUnless
from unittest.mock import AsyncMock, patch
from uuid import uuid4
from types import SimpleNamespace

import asyncpg
import httpx
from PIL import Image

TEST_DB = os.getenv('PORTAL_TEST_DATABASE_URL', '')
os.environ.setdefault('DATABASE_URL', TEST_DB or 'postgresql://unused')
from app import app
from account_portal import record_observation, hash_password, verify_password
from push_notifications import deliver_once


@skipUnless(TEST_DB, 'Set PORTAL_TEST_DATABASE_URL to an isolated PostgreSQL test database')
class AccountPortalTests(IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.schema = 'test_' + uuid4().hex
        connection = await asyncpg.connect(TEST_DB)
        await connection.execute('create extension if not exists pgcrypto')
        await connection.execute(f'create schema {self.schema}')
        await connection.close()
        self.pool = await asyncpg.create_pool(TEST_DB, min_size=1, max_size=5,
            server_settings={'search_path': self.schema + ',public'})
        async with self.pool.acquire() as connection:
            await connection.execute(Path('schema.sql').read_text())
        app.state.db = self.pool
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test')
        self.alice = await self.signup('Alice', 'alice@example.com', 'KA01AB1234')
        self.bob = await self.signup('Bob', 'bob@example.com', 'MH12AB1234')
        self.now = datetime.now(timezone.utc)
        output = BytesIO()
        Image.new('RGB', (160,80), 'white').save(output,format='JPEG')
        self.jpeg = output.getvalue()

    async def asyncTearDown(self):
        await self.client.aclose()
        await self.pool.close()
        connection = await asyncpg.connect(TEST_DB)
        await connection.execute(f'drop schema {self.schema} cascade')
        await connection.close()

    async def signup(self,name,email,plate):
        response = await self.client.post('/api/v1/auth/signup',json={'name':name,'email':email,'plate':plate,'password':'TestPassword123!'})
        self.assertEqual(response.status_code,201,response.text)
        return response.json()

    def headers(self,user):
        return {'Authorization':'Bearer '+user['token']}

    def decision(self,position='inside',plate='KA01AB1234'):
        return {'status':'recognized','position':position,'plate':plate,'fine':position=='inside','fine_amount':500 if position=='inside' else 0}

    async def test_accounts_cannot_claim_duplicate_vehicles_or_choose_admin_role(self):
        response = await self.client.post('/api/v1/auth/signup',json={'name':'Attacker','email':'attacker@example.com','plate':'KA01AB1234','password':'TestPassword123!','role':'admin'})
        self.assertEqual(response.status_code,422)
        response = await self.client.post('/api/v1/auth/signup',json={'name':'Other','email':'other@example.com','plate':'ka 01 ab 1234','password':'TestPassword123!'})
        self.assertEqual(response.status_code,409)
        async with self.pool.acquire() as connection:
            self.assertEqual(await connection.fetchval('select count(*) from portal_users'),2)
            stored = await connection.fetchval('select password_hash from portal_users where email=$1','alice@example.com')
        self.assertNotIn('TestPassword123!',stored)
        self.assertTrue(verify_password('TestPassword123!',stored))
        self.assertFalse(verify_password('wrong-password',stored))

    async def test_penalty_image_and_demo_payment_are_owner_scoped(self):
        penalty = await record_observation(self.pool,'camera',self.now,self.decision(),self.jpeg)
        alice = await self.client.get('/api/v1/penalties',headers=self.headers(self.alice))
        bob = await self.client.get('/api/v1/penalties',headers=self.headers(self.bob))
        self.assertEqual(len(alice.json()),1)
        self.assertEqual(bob.json(),[])
        self.assertEqual(alice.json()[0]['owner_name'],'Alice')
        for path,method in [(f'/api/v1/penalties/{penalty}/image','GET'),(f'/api/v1/penalties/{penalty}/demo-pay','POST'),(f'/api/v1/penalties/{penalty}/seen','POST')]:
            response = await self.client.request(method,path,headers=self.headers(self.bob))
            self.assertEqual(response.status_code,404)
        image = await self.client.get(f'/api/v1/penalties/{penalty}/image',headers=self.headers(self.alice))
        self.assertEqual(image.content,self.jpeg)
        self.assertEqual(image.headers['cache-control'],'no-store')
        receipts = await asyncio.gather(*[self.client.post(f'/api/v1/penalties/{penalty}/demo-pay',headers=self.headers(self.alice)) for _ in range(3)])
        self.assertEqual(len({r.json()['receipt_id'] for r in receipts}),1)
        self.assertTrue(all(r.json()['money_collected'] is False for r in receipts))
        self.assertTrue(all(r.json()['amount']==500 for r in receipts))

    async def test_repeated_analysis_and_retries_do_not_issue_duplicate_penalties(self):
        await asyncio.gather(*[record_observation(self.pool,'camera',self.now+timedelta(seconds=i),self.decision(),self.jpeg) for i in range(4)])
        async with self.pool.acquire() as c:
            self.assertEqual(await c.fetchval('select count(*) from portal_penalties'),1)
            self.assertEqual(await c.fetchval('select count(*) from portal_push_outbox'),1)
        await record_observation(self.pool,'camera',self.now+timedelta(seconds=5),self.decision('outside'),self.jpeg)
        await record_observation(self.pool,'camera',self.now+timedelta(seconds=6),self.decision(),self.jpeg)
        # A late/out-of-order empty response must not reopen the current encounter.
        await record_observation(self.pool,'camera',self.now+timedelta(seconds=4),{'status':'empty'},self.jpeg)
        await record_observation(self.pool,'camera',self.now+timedelta(seconds=7),self.decision(),self.jpeg)
        async with self.pool.acquire() as c:
            self.assertEqual(await c.fetchval('select count(*) from portal_penalties'),2)

    async def test_users_cannot_use_camera_or_admin_apis_and_logout_revokes_token(self):
        for path in ['/api/v1/admin/penalties','/api/v1/admin/users','/api/v1/cameras','/api/v1/dashboard','/api/v1/violations']:
            response = await self.client.get(path,headers=self.headers(self.alice))
            self.assertEqual(response.status_code,403,path)
            response = await self.client.get(path)
            self.assertEqual(response.status_code,401,path)
        response = await self.client.post('/api/v1/push/register',headers=self.headers(self.alice),json={'token':'a-device-token-for-tests'})
        self.assertEqual(response.status_code,200)
        await self.client.post('/api/v1/auth/logout',headers=self.headers(self.alice))
        self.assertEqual((await self.client.get('/api/v1/account',headers=self.headers(self.alice))).status_code,401)
        async with self.pool.acquire() as c:
            self.assertEqual(await c.fetchval('select count(*) from portal_push_tokens'),0)

    async def test_admin_analysis_creates_penalty_and_unmatched_plates_stay_admin_only(self):
        async with self.pool.acquire() as c:
            await c.execute("update portal_users set role='admin' where email='bob@example.com'")
        headers={**self.headers(self.bob),'Content-Type':'image/jpeg','X-Camera-Source':'camera-1',
            'X-Frame-Time':self.now.isoformat(),'X-Parking-Zone':json.dumps({'version':1,'aspect':2,'points':[[0,0],[1,0],[1,1],[0,1]]})}
        with patch('parking_analyzer.analyze',new=AsyncMock(return_value=self.decision())):
            response = await self.client.post('/api/v1/parking/analyze',headers=headers,content=self.jpeg)
        self.assertEqual(response.status_code,200,response.text)
        self.assertIsNotNone(response.json()['penalty_id'])
        await record_observation(self.pool,'camera-2',self.now,self.decision(plate='DL01AB5555'),self.jpeg)
        response = await self.client.get('/api/v1/admin/penalties',headers=self.headers(self.bob))
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.json()['summary']['total'],2)
        self.assertEqual(len((await self.client.get('/api/v1/penalties',headers=self.headers(self.alice))).json()),1)

    async def test_shared_phone_push_token_moves_to_current_account_only(self):
        token = 'shared-phone-notification-token'
        for user in [self.alice,self.bob]:
            response = await self.client.post('/api/v1/push/register',headers=self.headers(user),json={'token':token})
            self.assertEqual(response.status_code,200)
        await record_observation(self.pool,'alice-camera',self.now,self.decision(),self.jpeg)
        bob_penalty = await record_observation(self.pool,'bob-camera',self.now,self.decision(plate='MH12AB1234'),self.jpeg)
        response = SimpleNamespace(failure_count=0,responses=[SimpleNamespace(exception=None)])
        with patch('push_notifications.send_push',return_value=response) as send:
            await deliver_once(self.pool,object())
            send.assert_not_called()  # Alice has no registered device now.
            await deliver_once(self.pool,object())
            send.assert_called_once()
            self.assertEqual(send.call_args.args[1],[token])
            self.assertEqual(str(send.call_args.args[2]),self.bob['user']['id'])
            self.assertEqual(str(send.call_args.args[3]),bob_penalty)
