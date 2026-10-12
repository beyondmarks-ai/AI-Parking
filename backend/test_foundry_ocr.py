import json
import os
import unittest
from unittest.mock import patch
import httpx
from foundry_ocr import parse_plate, transcribe


class FoundryTests(unittest.IsolatedAsyncioTestCase):
    def test_unreadable_and_invalid_are_never_plates(self):
        self.assertIsNone(parse_plate('{"readable":false,"plate":"KA01AB1234"}'))
        self.assertIsNone(parse_plate('{"readable":true,"plate":"KAO1AB1234"}'))
        self.assertIsNone(parse_plate('{"readable":true,"plate":["KA01AB1234"]}'))
        self.assertEqual(parse_plate('```json\n{"readable":true,"plate":"KA 01 AB 1234"}\n```'), 'KA01AB1234')

    async def test_request_has_image_but_no_local_guess(self):
        def respond(request):
            body = json.loads(request.content)
            self.assertEqual(body['model'], 'test-vision')
            self.assertEqual(request.headers['api-key'], 'test-key')
            self.assertEqual(request.url.path, '/openai/deployments/test-vision/chat/completions')
            self.assertEqual(request.url.params['api-version'], '2024-10-21')
            self.assertEqual(body['messages'][0]['role'], 'system')
            image = body['messages'][1]['content'][0]['image_url']
            self.assertTrue(image['url'].startswith('data:image/jpeg;base64,'))
            self.assertEqual(image['detail'], 'high')
            self.assertTrue(body['response_format']['json_schema']['strict'])
            self.assertEqual(body['max_tokens'], 256)
            self.assertNotIn('local_plate', body)
            return httpx.Response(200, json={'choices': [{'finish_reason': 'stop',
                'message': {'content': '{"readable":true,"plate":"KA01AB1234"}'}}]})
        with patch.dict(os.environ, FOUNDRY_ENDPOINT='https://test.services.ai.azure.com',
                        FOUNDRY_MODEL='test-vision', FOUNDRY_API_KEY='test-key'):
            async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
                self.assertEqual(await transcribe(b'fake-test-image', client), 'KA01AB1234')

    async def test_truncated_model_output_is_not_accepted(self):
        with patch.dict(os.environ, FOUNDRY_ENDPOINT='https://test.services.ai.azure.com',
                        FOUNDRY_MODEL='test-vision', FOUNDRY_API_KEY='test-key'):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(200,
                    json={'choices': [{'finish_reason': 'length', 'message': {
                        'content': '{"readable":true,"plate":"KA01AB1234"}'}}]}))) as client:
                self.assertIsNone(await transcribe(b'fake-test-image', client))

    async def test_refusal_filter_empty_and_unreadable_are_not_accepted(self):
        payloads = [
            {'choices': []},
            {'choices': [{'finish_reason': 'content_filter', 'message': {}}]},
            {'choices': [{'finish_reason': 'stop', 'message': {'content': None}}]},
            {'choices': [{'finish_reason': 'stop', 'message': {
                'refusal': 'Cannot read', 'content': '{"readable":true,"plate":"KA01AB1234"}'}}]},
            {'choices': [{'finish_reason': 'stop', 'message': {
                'content': '{"readable":false,"plate":null}'}}]},
        ]
        with patch.dict(os.environ, FOUNDRY_ENDPOINT='https://test.openai.azure.com',
                        FOUNDRY_MODEL='test-vision', FOUNDRY_API_KEY='test-key'):
            for payload in payloads:
                with self.subTest(payload=payload):
                    async with httpx.AsyncClient(transport=httpx.MockTransport(
                            lambda r: httpx.Response(200, json=payload))) as client:
                        self.assertIsNone(await transcribe(b'fake-test-image', client))

if __name__ == '__main__':
    unittest.main()
