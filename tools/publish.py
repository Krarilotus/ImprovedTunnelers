"""Publish module/ into the game's module folder under the version in definition.yml.

The UCP GUI notices a new version on F5 and moves the pin with its apply button, so a
build is always *copied* to a new folder and the one before it is left installed. Anything
older than that is cleared out, because the GUI shows every folder it finds.

    python tools/publish.py            # copy module/ to improved-tunnelers-<version>
    python tools/publish.py --bump     # raise the last version slot first
"""
import os, re, shutil, sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE = os.path.join(HERE, 'module')
MODULES = r'H:\steam\steamapps\common\Stronghold Crusader Extreme UCP3 new\ucp\modules'
NAME = 'improved-tunnelers'


def version(text):
    return tuple(int(part) for part in text.split('.'))


def read_version():
    path = os.path.join(MODULE, 'definition.yml')
    with open(path, encoding='utf-8') as f:
        text = f.read()
    return re.search(r'^version:\s*(\S+)', text, re.M).group(1), path, text


def bump():
    current, path, text = read_version()
    parts = current.split('.')
    parts[-1] = str(int(parts[-1]) + 1)
    new = '.'.join(parts)
    text = re.sub(r'^version:\s*\S+', 'version: ' + new, text, count=1, flags=re.M)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print('%s -> %s' % (current, new))
    return new


def installed():
    found = []
    for entry in os.listdir(MODULES):
        if entry.startswith(NAME + '-') and os.path.isdir(os.path.join(MODULES, entry)):
            tail = entry[len(NAME) + 1:]
            if re.fullmatch(r'\d+(\.\d+)*', tail):
                found.append((version(tail), entry))
    return sorted(found)


def main():
    current = bump() if '--bump' in sys.argv else read_version()[0]
    target = os.path.join(MODULES, '%s-%s' % (NAME, current))
    if os.path.isdir(target):
        shutil.rmtree(target)
    shutil.copytree(MODULE, target)
    print('published', os.path.basename(target))

    keep = {version(current)}
    others = [v for v, _ in installed() if v != version(current)]
    if others:
        keep.add(max(others))                      # the build before this one stays
    for v, entry in installed():
        if v not in keep:
            shutil.rmtree(os.path.join(MODULES, entry))
            print('cleared', entry)
    print('installed:', ', '.join(entry for _, entry in installed()))


if __name__ == '__main__':
    main()
