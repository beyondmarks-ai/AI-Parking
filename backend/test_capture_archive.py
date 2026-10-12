from datetime import datetime, timezone
from io import BytesIO
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch, MagicMock
from uuid import uuid4
import os
import json

from azure.core.exceptions import HttpResponseError, ResourceNotFoundError
from fastapi import FastAPI, HTTPException
import httpx
from PIL import Image

import capture_archive as archive


class ArchiveTests(IsolatedAsyncioTestCase):
    async def test_image_decision_metadata_is_consistent(self):
        zone = json.dumps({'version': 1, 'aspect': 2, 'points': [[0, 0], [1, 0], [1, 1], [0, 1]]})
        with patch.object(archive, 'store_snapshot', return_value={'saved': True}) as store:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url='http://test') as client:
                for position, fine in [('inside', '500'), ('outside', '0')]:
                    response = await client.put(f'/api/v1/captures/{uuid4()}', content=self.jpeg,
                        headers={**self.headers, 'X-Parking-Zone': zone, 'X-Parking-Decision': position, 'X-Fine-Amount': fine})
                    self.assertEqual(response.status_code, 200)
                    self.assertEqual(store.call_args.args[2]['fine_amount'], fine)
                    self.assertEqual(store.call_args.args[2]['zone_observation'], 'client_image_analysis_' + position)
                store.reset_mock()
                response = await client.put(f'/api/v1/captures/{uuid4()}', content=self.jpeg,
                    headers={**self.headers, 'X-Parking-Zone': zone, 'X-Parking-Decision': 'outside', 'X-Fine-Amount': '500'})
                self.assertEqual(response.status_code, 422)
                store.assert_not_called()

    async def test_zone_metadata_and_invalid_geometry(self):
        zone = {'version': 1, 'aspect': 2, 'points': [[0, 0], [1, 0], [1, 1], [0, 1]]}
        with patch.object(archive, 'store_snapshot', return_value={'saved': True}) as store:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                         base_url='http://test') as client:
                response = await client.put(f'/api/v1/captures/{uuid4()}', content=self.jpeg,
                    headers={**self.headers, 'X-Parking-Zone': json.dumps(zone)})
                self.assertEqual(response.status_code, 200)
                self.assertEqual(json.loads(store.call_args.args[2]['parking_zone']), zone)
                self.assertEqual(store.call_args.args[2]['zone_observation'], 'client_plate_in_bay_needs_review')
                store.reset_mock()
                for bad in ['{}', 'null', '[]', '{', json.dumps({**zone, 'aspect': 1}),
                            json.dumps({**zone, 'points': [[0, 0], [1, 1], [1, 0], [0, 1]]}),
                            json.dumps({**zone, 'points': [[0, 0], [.001, 0], [.001, .001], [0, .001]]}),
                            json.dumps({**zone, 'aspect': float('nan')})]:
                    response = await client.put(f'/api/v1/captures/{uuid4()}', content=self.jpeg,
                        headers={**self.headers, 'X-Parking-Zone': bad})
                    self.assertEqual(response.status_code, 422, bad)
                store.assert_not_called()

    def setUp(self):
        archive._requests.clear()
        self.app = FastAPI()
        self.app.include_router(archive.router)
        buf = BytesIO()
        Image.new('RGB', (64, 32), 'white').save(buf, format='JPEG')
        self.jpeg = buf.getvalue()
        self.headers = {'Content-Type': 'image/jpeg', 'X-Plate-Number': 'KA01AB1234',
                        'X-Captured-At': datetime.now(timezone.utc).isoformat(),
                        'X-Ocr-Provider': 'local OCR: multiple frames'}

    async def test_saves_jpeg_and_metadata_without_public_url(self):
        capture_id = uuid4()
        with patch.object(archive, 'store_snapshot', return_value={
                'id': str(capture_id), 'plate': 'KA01AB1234', 'saved': True}) as store:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                         base_url='http://test') as client:
                response = await client.put(f'/api/v1/captures/{capture_id}',
                                            headers=self.headers, content=self.jpeg)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()['saved'])
        self.assertNotIn('url', response.json())
        args = store.call_args.args
        self.assertEqual(args[1], self.jpeg)
        self.assertEqual(args[2]['plate'], 'KA01AB1234')
        self.assertEqual(len(args[2]['sha256']), 64)

    async def test_invalid_requests_never_reach_storage(self):
        with patch.object(archive, 'store_snapshot') as store:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                         base_url='http://test') as client:
                for headers, data in [
                    ({**self.headers, 'X-Plate-Number': 'UNKNOWN'}, self.jpeg),
                    ({**self.headers, 'X-Captured-At': '2026-01-01T12:00:00'}, self.jpeg),
                    (self.headers, b'not a jpeg'),
                    ({**self.headers, 'Content-Type': 'image/png'}, self.jpeg),
                    (self.headers, b'x' * (archive.MAX_BYTES + 1)),
                ]:
                    response = await client.put(f'/api/v1/captures/{uuid4()}',
                                                headers=headers, content=data)
                    self.assertIn(response.status_code, (413, 415, 422))
        store.assert_not_called()

    def test_retry_is_idempotent_and_conflicting_overwrite_is_rejected(self):
        blob = MagicMock()
        blob.upload_blob.side_effect = HttpResponseError('create-only SAS duplicate', status_code=403)
        metadata = {'plate': 'KA01AB1234', 'captured_at': 'test', 'sha256': 'abc'}
        props = MagicMock()
        props.metadata = metadata
        blob.get_blob_properties.side_effect = [ResourceNotFoundError('missing'), props, props]
        with patch.dict(os.environ, CAPTURE_STORAGE_URL='https://test.blob.core.windows.net',
                        CAPTURE_STORAGE_SAS='test-not-secret'), \
                patch.object(archive, 'BlobClient') as factory:
            factory.return_value.__enter__.return_value = blob
            capture_id = uuid4()
            self.assertTrue(archive.store_snapshot(capture_id, self.jpeg, metadata)['saved'])
            self.assertFalse(blob.upload_blob.call_args.kwargs['overwrite'])
            with self.assertRaises(HTTPException) as caught:
                archive.store_snapshot(capture_id, self.jpeg, {**metadata, 'sha256': 'different'})
            self.assertEqual(caught.exception.status_code, 409)
