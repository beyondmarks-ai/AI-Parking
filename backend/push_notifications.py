"""Durable, account-targeted FCM delivery; inbox remains the source of truth."""
import asyncio
import base64
from datetime import timedelta
import json
import logging
import os

import firebase_admin
from firebase_admin import credentials, messaging

logger = logging.getLogger(__name__)


def initialize_push():
    encoded = os.getenv('FCM_SERVICE_ACCOUNT_BASE64', '')
    raw = base64.b64decode(encoded, validate=True).decode('utf-8') if encoded else os.getenv('FCM_SERVICE_ACCOUNT_JSON', '')
    if not raw:
        logger.warning('Background push not configured; penalty inbox remains available')
        return None
    return firebase_admin.initialize_app(credentials.Certificate(json.loads(raw)), name='parkguard-push')


def send_push(app, tokens, owner, penalty):
    # Data messages let the handset check the signed-in owner before showing
    # a notification, including after an account switch on a shared phone.
    message = messaging.MulticastMessage(tokens=tokens,
        data={'owner_id':str(owner),'penalty_id':str(penalty)},
        android=messaging.AndroidConfig(priority='high', ttl=timedelta(hours=24)))
    return messaging.send_each_for_multicast(message, app=app)


async def deliver_once(pool, app):
    async with pool.acquire() as connection, connection.transaction():
        row = await connection.fetchrow('''select * from portal_push_outbox
            where sent_at is null and attempts<10 and next_attempt<=now()
            order by next_attempt for update skip locked limit 1''')
        if row is None:
            return
        tokens = await connection.fetch('''select t.token from portal_push_tokens t join portal_sessions s
            on s.token_hash=t.session_hash where t.user_id=$1 and s.expires_at>now() limit 100''', row['owner_id'])
        await connection.execute("update portal_push_outbox set attempts=attempts+1,next_attempt=now()+interval '2 minutes' where penalty_id=$1", row['penalty_id'])
        if not tokens:
            return
        try:
            result = await asyncio.to_thread(send_push, app, [t['token'] for t in tokens],row['owner_id'],row['penalty_id'])
            for token, response in zip(tokens, result.responses):
                if isinstance(response.exception, messaging.UnregisteredError):
                    await connection.execute('delete from portal_push_tokens where token=$1', token['token'])
            if result.failure_count == 0:
                await connection.execute('update portal_push_outbox set sent_at=now() where penalty_id=$1',row['penalty_id'])
        except Exception:
            logger.warning('Push delivery failed; retry remains queued')


async def push_worker(pool, app):
    while True:
        try:
            await deliver_once(pool, app)
        except Exception:
            logger.warning('Push worker will retry')
        await asyncio.sleep(5)
