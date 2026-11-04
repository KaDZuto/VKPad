import subprocess

svg_icon = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect width="512" height="512" rx="112" fill="#0077FF"/>
  <!-- VK and Music note aesthetic icon -->
  <path d="M 276 370 C 170 370 108 296 106 172 L 158 172 C 160 263 200 302 232 310 L 232 172 L 282 172 L 282 250 C 312 247 344 211 355 172 L 405 172 C 397 221 361 257 335 272 C 361 285 403 316 418 370 L 363 370 C 351 332 320 302 282 298 L 282 370 Z" fill="#FFFFFF"/>
</svg>'''

with open('/tmp/vk_icon.svg', 'w') as f:
    f.write(svg_icon)

sizes = {
    'icon.png': 120,
    'AppIcon76x76~ipad.png': 76,
    'AppIcon76x76@2x~ipad.png': 152,
    'AppIcon83.5x83.5@2x~ipad.png': 167
}

for name, s in sizes.items():
    out_path = '/home/alexius/Projects/LinuxiOSBuilder-full-starter/LinuxiOSBuilder/VKPad/' + name
    subprocess.run(['rsvg-convert', '-w', str(s), '-h', str(s), '-f', 'png', '-o', out_path, '/tmp/vk_icon.svg'], check=True)
    print(f'Generated {name}')
