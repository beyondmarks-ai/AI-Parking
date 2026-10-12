import base64
from io import BytesIO
import json
import os
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch, AsyncMock
from fastapi import FastAPI
import httpx
from PIL import Image
import parking_analyzer as analyzer


class ParkingAnalyzerTests(IsolatedAsyncioTestCase):
    def setUp(self):
        buf = BytesIO()
        Image.new('RGB', (160, 80), 'white').save(buf, format='JPEG')
        self.jpeg = buf.getvalue()
        self.zone = {'version': 1, 'aspect': 2, 'points': [[0, 0], [.5, 0], [.5, 1], [0, 1]]}
        analyzer._requests.clear()

    def test_only_clear_single_vehicle_and_plate_produces_fine_decision(self):
        with patch.dict(os.environ, PARKING_FINE_AMOUNT='500'):
            inside = analyzer.decision({'vehicle': 'single', 'plate': 'KA 58 W 0344', 'position': 'inside'})
            outside = analyzer.decision({'vehicle': 'single', 'plate': 'KA58W0344', 'position': 'outside'})
        self.assertEqual((inside['plate'], inside['fine_amount'], inside['fine']), ('KA58W0344', 500, True))
        self.assertEqual((outside['fine_amount'], outside['fine']), (0, False))
        for value in [None, {}, {'vehicle': 'multiple', 'plate': 'KA58W0344', 'position': 'inside'},
                      {'vehicle': 'single', 'plate': 'KA58W0344', 'position': 'uncertain'},
                      {'vehicle': 'single', 'plate': None, 'position': 'inside'},
                      {'vehicle': 'single', 'plate': 'KAO1AB1234', 'position': 'inside'},
                      {'vehicle': 'none', 'plate': 'KA58W0344', 'position': 'outside'}]:
            result = analyzer.decision(value)
            self.assertEqual(result['status'], 'uncertain')
            self.assertIsNone(result['fine'])
            self.assertIsNone(result['fine_amount'])
        self.assertEqual(analyzer.decision({'vehicle': 'none', 'plate': None, 'position': 'uncertain'})['status'], 'empty')

    async def test_model_receives_original_and_outline_not_mask_or_ocr_guess(self):
        def respond(request):
            body = json.loads(request.content)
            parts = body['messages'][1]['content']
            originals = [p['image_url']['url'] for p in parts if p['type'] == 'image_url']
            self.assertEqual(len(originals), 2)
            self.assertEqual(base64.b64decode(originals[0].split(',')[1]), self.jpeg)
            annotated = Image.open(BytesIO(base64.b64decode(originals[1].split(',')[1])))
            self.assertGreater(annotated.getpixel((140, 40))[0], 240)  # Outside remains visible.
            self.assertTrue(body['response_format']['json_schema']['strict'])
            self.assertNotIn('local_plate', json.dumps(body))
            return httpx.Response(200, json={'choices': [{'finish_reason': 'stop', 'message': {
                'content': json.dumps({'vehicle': 'single', 'plate': 'KA58W0344', 'position': 'outside'})}}]})
        with patch.dict(os.environ, FOUNDRY_ENDPOINT='https://test.openai.azure.com',
                        FOUNDRY_MODEL='test-mini', FOUNDRY_API_KEY='test-key'):
            async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
                result = await analyzer.analyze(self.jpeg, self.zone, client)
        self.assertEqual(result['fine_amount'], 0)

    async def test_refusal_or_truncation_cannot_become_no_fine(self):
        with patch.dict(os.environ, FOUNDRY_ENDPOINT='https://test.openai.azure.com',
                        FOUNDRY_MODEL='test-mini', FOUNDRY_API_KEY='test-key'):
            for payload in [{'choices': []}, {'choices': [{'finish_reason': 'length'}]},
                            {'choices': [{'finish_reason': 'stop', 'message': {'refusal': 'no'}}]}]:
                async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=payload))) as client:
                    result = await analyzer.analyze(self.jpeg, self.zone, client)
                self.assertIsNone(result['fine'])

    async def test_route_validates_zone_and_image_before_model(self):
        app = FastAPI()
        app.include_router(analyzer.router)
        headers = {'Content-Type': 'image/jpeg', 'X-Parking-Zone': json.dumps(self.zone)}
        with patch.object(analyzer, 'analyze', new_callable=AsyncMock) as model:
            model.return_value = analyzer.decision(None)
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
                for modified, content in [({'X-Parking-Zone': '{}'}, self.jpeg),
                                           ({'Content-Type': 'image/png'}, self.jpeg), ({}, b'bad jpeg')]:
                    response = await client.post('/api/v1/parking/analyze', headers={**headers, **modified}, content=content)
                    self.assertIn(response.status_code, (415, 422))
                model.assert_not_called()
                response = await client.post('/api/v1/parking/analyze', headers=headers, content=self.jpeg)
                self.assertEqual(response.status_code, 200)
                self.assertIsNone(response.json()['fine'])
