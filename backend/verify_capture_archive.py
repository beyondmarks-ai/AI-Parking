"""Store one explicitly labeled synthetic test snapshot; never use a live camera."""
import asyncio
import argparse
from datetime import datetime, timezone
import json
from uuid import uuid4
import httpx
from verify_foundry import sample


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('base_url')
    parser.add_argument('capture_id', nargs='?', default=str(uuid4()))
    parser.add_argument('captured_at', nargs='?', default=datetime.now(timezone.utc).isoformat())
    parser.add_argument('--zone', action='store_true')
    args = parser.parse_args()
    capture_id = args.capture_id
    url = args.base_url.rstrip('/') + '/api/v1/captures/' + capture_id
    headers = {'Content-Type': 'image/jpeg', 'X-Plate-Number': 'KA01AB1234',
               'X-Captured-At': args.captured_at,
               'X-Ocr-Provider': 'synthetic-deployment-test'}
    if args.zone:
        headers['X-Parking-Zone'] = json.dumps({'version': 1, 'aspect': 600 / 140,
            'points': [[0, 0], [1, 0], [1, 1], [0, 1]]}, separators=(',', ':'))
    async with httpx.AsyncClient(timeout=35) as client:
        if args.zone:
            invalid = await client.put(url, content=sample(),
                headers={**headers, 'X-Parking-Zone': '{}'})
            assert invalid.status_code == 422, invalid.text
            print('Invalid zone correctly rejected before storage')
        for _ in range(2):
            response = await client.put(url, content=sample(), headers=headers)
            print(response.status_code, response.text[:500])
            response.raise_for_status()
            assert response.json().get('saved') is True
            assert response.json().get('id') == capture_id
    print('Synthetic test snapshot ID:', capture_id)


if __name__ == '__main__':
    asyncio.run(main())
