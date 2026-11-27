# Third-party notices

## Chromium material referenced in the CRX3 verifier

`src/Crx3.cs` uses the wire identifiers and signature context from Chromium's
[CRX3 format](https://chromium.googlesource.com/chromium/src/+/main/components/crx_file/crx3.proto)
and the production Web Store publisher key hash from its
[CRX verifier](https://chromium.googlesource.com/chromium/src/+/main/components/crx_file/crx_verifier.cc).
The updater implements verification in C# using .NET APIs. The following
notice preserves the upstream BSD-3-Clause terms for the Chromium material.

> Copyright 2017 The Chromium Authors
>
> Copyright 2015 The Chromium Authors
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are
> met:
>
>    * Redistributions of source code must retain the above copyright
> notice, this list of conditions and the following disclaimer.
>    * Redistributions in binary form must reproduce the above
> copyright notice, this list of conditions and the following disclaimer
> in the documentation and/or other materials provided with the
> distribution.
>    * Neither the name of Google LLC nor the names of its
> contributors may be used to endorse or promote products derived from
> this software without specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
> "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
> LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
> A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
> OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
> SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
> LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
> DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
> THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
> (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
> OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## External tools and runtime downloads

These acknowledgements identify software obtained separately. External
projects retain their own licenses and notices.

| Component | How the updater uses it | Upstream terms |
| --- | --- | --- |
| [Chromium](https://www.chromium.org/) | Browser engine in the Windows distribution | [BSD-3-Clause](https://chromium.googlesource.com/chromium/src/+/main/LICENSE) and component notices available at `chrome://credits` |
| [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium) and [ungoogled-chromium Windows](https://github.com/ungoogled-software/ungoogled-chromium-windows) | Browser patches and the official Windows installer fetched at runtime | [BSD-3-Clause for the patch project](https://github.com/ungoogled-software/ungoogled-chromium/blob/master/LICENSE) and [BSD-3-Clause for the Windows packaging project](https://github.com/ungoogled-software/ungoogled-chromium-windows/blob/master/LICENSE), alongside the terms of the components in each distribution |
| [uBlock Origin](https://github.com/gorhill/uBlock) | Signed extension downloaded for the compatibility fixture and extension checks | [GPL-3.0 and upstream notices](https://github.com/gorhill/uBlock/blob/master/LICENSE.txt) |
| [Chromium Web Store](https://github.com/NeverDecaf/chromium-web-store) | Separate extension whose official channel the updater checks | [MIT](https://github.com/NeverDecaf/chromium-web-store/blob/master/LICENSE) |
| [7-Zip](https://www.7-zip.org/) | User-installed tool for verified installer extraction | [LGPL with other component terms, including BSD and the unRAR restriction](https://www.7-zip.org/license.txt) |
| [PowerShell 7](https://github.com/PowerShell/PowerShell) | User-installed runtime | [MIT and upstream third-party notices](https://github.com/PowerShell/PowerShell/blob/master/LICENSE.txt) |
| [Windows .NET Framework](https://learn.microsoft.com/en-us/dotnet/framework/get-started/system-requirements) and Windows utilities | System-provided compiler, launcher runtime, and backup support | Terms of the installed Microsoft distribution |

The updater also contacts Google services for [Chrome Version History](https://developer.chrome.com/docs/web-platform/versionhistory/guide)
and the [Chrome Web Store extension update service](https://developer.chrome.com/docs/extensions/how-to/distribute/host-on-linux).
Store extension packages remain subject to the individual publishers' terms.
