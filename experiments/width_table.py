import unicodedata

def ranges(pred, limit=0x110000):
    out = []
    start = None
    for cp in range(limit):
        if 0xD800 <= cp <= 0xDFFF:
            v = False
        else:
            try:
                ch = chr(cp)
            except ValueError:
                v = False
            else:
                v = pred(ch, cp)
        if v and start is None:
            start = cp
        elif not v and start is not None:
            out.append((start, cp - 1))
            start = None
    if start is not None:
        out.append((start, limit - 1))
    return out

def cps(rs):
    return sum(b - a + 1 for a, b in rs)

wide = ranges(lambda ch, cp: unicodedata.east_asian_width(ch) in ('W', 'F'))
amb = ranges(lambda ch, cp: unicodedata.east_asian_width(ch) == 'A')
zero = ranges(lambda ch, cp: unicodedata.category(ch) in ('Mn', 'Me', 'Cf'))

print("unicode data version:", unicodedata.unidata_version)
print()
print(f"wide/fullwidth:  {len(wide):5d} ranges, {cps(wide):7d} codepoints")
print(f"ambiguous (A):   {len(amb):5d} ranges, {cps(amb):7d} codepoints")
print(f"zero-width:      {len(zero):5d} ranges, {cps(zero):7d} codepoints")
print()
# Rough encodings for the *needed* table: wide + zero-width ranges.
n = len(wide) + len(zero)
print("encoding options for wide+zero ranges:")
print(f"  (u32 start, u32 end) x {n}:              {n * 8:,} bytes")
print(f"  (u32 start, u16 len) x {n}:              {n * 6:,} bytes")
print(f"  varint delta start + u16 len x {n}:      ~{n * 4:,} bytes")
print()
# Emoji block specifically
emoji = ranges(lambda ch, cp: 0x1F000 <= cp <= 0x1FAFF)
print(f"emoji blocks U+1F000-1FAFF: {len(emoji)} ranges, {cps(emoji)} codepoints")
