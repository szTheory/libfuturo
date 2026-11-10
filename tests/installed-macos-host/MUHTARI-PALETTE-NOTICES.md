# Muhtari warm NTSC palette notices

`LFDisplayAdapter.m` copies the 256-entry warm NTSC table from `host/palette.c`
in Muhtari commit
`d5fd241e3f4d701d73867cc2e465c56a6fe6793d` (source SHA-256
`d48f699211ee046cd3921894036686fe7f741b0c56e169d6ac4c97e3476b419b`). The
table is the 16 `ntsc_hue*_warm` rows in the block “26.7 PHASE SHIFT - LUM3
from TREBORS PRO PALETTES V7” and stores `0x00RRGGBB` values. The libfuturo
adapter retains the NTSC rows and converts them into a separate opaque RGBA8
surface; raw Muhtari INDEX8 bytes remain unchanged.

Muhtari identifies its palette source as `src/mame/drivers/a7800.cpp` from
`7800-devtools/a7800` commit
`7a2afdc1ea08fc331b16b750d8c1f02d4ef62fc8`, SHA-256
`504b221d6dd1726cabd600b795a0243a6353d4642827f7d1bc438ea1d8ce31c2`. The
table carries both the MIT license for Muhtari's transcription and the
BSD-3-Clause license for the source material. These colors are an emulator
palette approximation, not calibrated Atari hardware or CRT output.

The libfuturo maintainers own the host adapter and must keep this notice with
the copied table in source and relocated host distributions. If the palette
source pin or copied material changes, update this provenance and both license
texts.

## MIT License

Copyright (c) 2026 muhtari contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## BSD 3-Clause License

Copyright (c) Dan Boris, Fabio Priuli, Mike Saarna, Robert Tuccitto

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
