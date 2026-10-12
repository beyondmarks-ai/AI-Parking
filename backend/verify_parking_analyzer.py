"""Generated inside/outside/empty scenes. Never contacts the live camera/LCD."""
import asyncio
from io import BytesIO
import json
import sys
import httpx
from PIL import Image, ImageDraw, ImageFont


def scene(position):
    image = Image.new('RGB', (800, 500), '#dedede')
    if position != 'empty':
        x = 470 if position == 'inside' else 50
        draw = ImageDraw.Draw(image)
        # Top-view model car: tyres, body, glass, lamps, and attached test plate.
        draw.rounded_rectangle((x - 10, 150, x + 35, 205), radius=8, fill='black')
        draw.rounded_rectangle((x + 185, 150, x + 230, 205), radius=8, fill='black')
        draw.rounded_rectangle((x - 10, 295, x + 35, 350), radius=8, fill='black')
        draw.rounded_rectangle((x + 185, 295, x + 230, 350), radius=8, fill='black')
        draw.rounded_rectangle((x, 100, x + 220, 390), radius=45, fill='#2676bb', outline='black', width=3)
        draw.polygon([(x + 35, 155), (x + 185, 155), (x + 170, 210), (x + 50, 210)], fill='#384650')
        draw.rectangle((x + 45, 275, x + 175, 310), fill='#384650')
        draw.ellipse((x + 25, 115, x + 60, 135), fill='white')
        draw.ellipse((x + 160, 115, x + 195, 135), fill='white')
        draw.rectangle((x + 7, 220, x + 213, 267), fill='white', outline='black')
        font = ImageFont.truetype('C:/Windows/Fonts/arialbd.ttf', 31)
        draw.text((x + 10, 225), 'KA01AB1234', font=font, fill='black')
    buf = BytesIO()
    image.save(buf, 'JPEG', quality=98)
    return buf.getvalue()


async def main():
    zone = {'version': 1, 'aspect': 1.6, 'points': [[.52, .08], [.96, .08], [.96, .92], [.52, .92]]}
    async with httpx.AsyncClient(timeout=35) as client:
        for position in ['inside', 'outside', 'empty']:
            response = await client.post(sys.argv[1].rstrip('/') + '/api/v1/parking/analyze',
                content=scene(position), headers={'Content-Type': 'image/jpeg', 'X-Parking-Zone': json.dumps(zone)})
            print(position, response.status_code, response.text)
            response.raise_for_status()
            value = response.json()
            if position == 'empty':
                assert value['status'] == 'empty' and value['fine'] is None
            else:
                assert value['status'] == 'recognized' and value['plate'] == 'KA01AB1234'
                assert value['position'] == position and value['fine'] == (position == 'inside')
                assert value['fine_amount'] == (500 if position == 'inside' else 0)


if __name__ == '__main__':
    asyncio.run(main())
