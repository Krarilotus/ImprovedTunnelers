"""Packaging/default checks and optional real-image Lua lifecycle checks.

python -m unittest discover -s bench -p test_integration.py -v
Set SHC_GAME_DIR to a licensed SHC/Extreme fixture directory for lifecycle cases.
Those cases stub assembly generation: they verify Lua admission/lifecycle only,
not emitted instructions, gameplay, text encoding or native compatibility.
"""
import os
from pathlib import Path
import re
import unittest
from unittest.mock import patch
import yaml
from lupa.lua54 import LuaRuntime

MODULE = Path(__file__).resolve().parents[1] / 'module'
LANGUAGES = ('en', 'de', 'fr', 'es', 'tr', 'ru', 'hu', 'ch', 'fa')


class IntegrationTests(unittest.TestCase):
    def test_locales_manifest_and_defaults(self):
        options = yaml.safe_load((MODULE / 'options.yml').read_text(encoding='utf-8'))
        keys = set(re.findall(r'{{(.*?)}}', (MODULE / 'options.yml').read_text()))
        for lang in LANGUAGES:
            catalog = yaml.safe_load((MODULE / f'locale/{lang}.yml').read_text(encoding='utf-8'))
            self.assertEqual(keys, catalog.keys())
            self.assertTrue(all(isinstance(v, str) and v.strip() for v in catalog.values()))
            self.assertTrue((MODULE / f'locale/description-{lang}.md').read_text(encoding='utf-8').strip())
        self.assertEqual((MODULE / 'description.md').read_bytes(), (MODULE / 'locale/description-en.md').read_bytes())
        for entry in yaml.safe_load((MODULE / 'files.yml').read_text())['files']:
            self.assertTrue((MODULE / entry['src']).exists())
        # Execute the module's real DEFAULTS, exposed only in this test's copy.
        lua = LuaRuntime()
        lua.execute('core={}; package.preload.templates=function() return {} end')
        source = (MODULE / 'init.lua').read_text(encoding='utf-8')
        defaults = lua.execute(source[:source.index('\nreturn {\n\n  enable')] + '\nreturn DEFAULTS')
        for group in options['options']:
            for option in group['children']:
                _, section, name = option['url'].split('.')
                self.assertEqual(option['contents']['value'], defaults[section][name], option['url'])
        lua.execute(source)  # Compile/load the complete entry point too.
        messages = lua.execute((MODULE / 'messages.lua').read_text(encoding='utf-8'))
        for key in ('english', 'american', 'german', 'french', 'spanish', 'turkish',
                    'russian', 'hungarian', 'chinese', 'persian', 'italian', 'polish'):
            self.assertTrue(messages[key])
        self.assertNotIn('aiSwapper', yaml.safe_load((MODULE / 'definition.yml').read_text())['dependencies'])

    @unittest.skipUnless(os.environ.get('SHC_GAME_DIR'), 'licensed executable fixtures not supplied')
    def test_refusal_lifecycle_and_rejection(self):
        from harness import Host
        # Keep native payload validation separate; no generated code is executed.
        with patch.object(Host, 'allocate_assembly', lambda self, *_: self.allocate(16)):
            for extreme in (False, True):
                h = Host(extreme=extreme, language='German', after_init=False)
                self.assertEqual(h.texts, [])
                self.assertEqual(len(h.after_init), 1)
                before = len(h.patched)
                h.after_init[0]()
                self.assertEqual(h.texts[0][2], 'Der Boden ist hier noch zu instabil zum Bauen')
                self.assertGreater(len(h.patched), before)
                count = len(h.patched)
                h.after_init[0]()
                self.assertEqual(len(h.patched), count)
                for kwargs in ({'language': None}, {'language': 'unknown'},
                               {'accept_text': False}, {'texts': False}):
                    h = Host(extreme=extreme, after_init=False, **kwargs)
                    before = len(h.patched)
                    h.after_init[0]()
                    self.assertEqual(len(h.patched), before)
                h = Host(extreme=extreme, after_init=False)
                h.mod[b'disable'](h.mod, h.to_lua({}))
                before = len(h.patched)
                h.after_init[0]()
                self.assertEqual(h.texts, [])
                self.assertEqual(len(h.patched), before)
                h = Host(extreme=extreme, config={'denial': {'message': False}})
                self.assertEqual(h.after_init, [])
                self.assertEqual(h.texts, [])


if __name__ == '__main__':
    unittest.main()
