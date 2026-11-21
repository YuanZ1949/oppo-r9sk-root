#!/usr/bin/env python3
"""Dump Android binary XML (AndroidManifest.xml) as an indented tree with attributes.
Usage: python axml_dump.py <apk-or-xml>
"""
import sys, zipfile, struct

def u16(b, o): return struct.unpack('<H', b[o:o+2])[0]
def u32(b, o): return struct.unpack('<I', b[o:o+4])[0]

def load(path):
    if path.lower().endswith('.apk'):
        return zipfile.ZipFile(path).read('AndroidManifest.xml')
    return open(path, 'rb').read()

def parse_strings(d):
    off = 8
    ctype, hsize, csize = u16(d, off), u16(d, off+2), u32(d, off+4)
    sp = d[off:off+csize]
    scount, styleCount, flags, sstart, systart = struct.unpack('<IIIII', sp[8:28])
    utf8 = bool(flags & 0x100)
    offs = struct.unpack('<%dI' % scount, sp[28:28+4*scount])
    out = []
    for o in offs:
        p = sstart + o
        if utf8:
            n = sp[p]; p += 1
            if n & 0x80: n = ((n & 0x7f) << 8) | sp[p]; p += 1
            m = sp[p]; p += 1
            if m & 0x80: m = ((m & 0x7f) << 8) | sp[p]; p += 1
            out.append(sp[p:p+m].decode('utf-8', 'replace'))
        else:
            n = u16(sp, p); p += 2
            if n & 0x8000:
                n = ((n & 0x7fff) << 16) | u16(sp, p); p += 2
            out.append(sp[p:p+n*2].decode('utf-16-le', 'replace'))
    return out, off + csize

def dump(path, out=sys.stdout):
    d = load(path)
    strings, p = parse_strings(d)
    # skip resource map chunk if present
    t, h, s = u16(d, p), u16(d, p+2), u32(d, p+4)
    if t == 0x0180:
        p += s
    depth = 0
    while p + 8 <= len(d):
        ct, ch, cs = u16(d, p), u16(d, p+2), u32(d, p+4)
        if cs == 0:
            break
        if ct == 0x0102:  # start element
            name = strings[u32(d, p+20)]
            astart, asize, acount = u16(d, p+24), u16(d, p+26), u16(d, p+28)
            base = p + 16 + astart
            attrs = []
            for i in range(acount):
                a = base + i*asize
                aname = strings[u32(d, a+4)]
                raw = u32(d, a+8)
                dtype = d[a+15]
                dval = u32(d, a+16)
                if dtype == 3:
                    val = strings[dval] if dval < len(strings) else '?'
                elif dtype == 0x12:
                    val = 'true' if dval else 'false'
                elif dtype == 0x10 or dtype == 0x11:
                    val = str(struct.unpack('<i', struct.pack('<I', dval))[0])
                elif dtype == 1:
                    val = '@0x%08x' % dval
                else:
                    val = '0x%x' % dval
                attrs.append('%s="%s"' % (aname, val))
            out.write('%s<%s %s>\n' % ('  '*depth, name, ' '.join(attrs)))
            depth += 1
        elif ct == 0x0103:  # end element
            depth = max(0, depth-1)
        p += cs

if __name__ == '__main__':
    dump(sys.argv[1])
