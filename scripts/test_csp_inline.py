#!/usr/bin/env python3
# Unit fixtures for csp-inline.py. Stdlib unittest only (no dependency). Run:
#   python3 scripts/test_csp_inline.py
import importlib.util
import pathlib
import unittest

_spec = importlib.util.spec_from_file_location(
    "csp_inline", pathlib.Path(__file__).with_name("csp-inline.py")
)
csp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(csp)

# Independent sha256-base64 vectors (computed via openssl, not via the impl).
EMPTY = "'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU='"
ALERT1 = "'sha256-bhHHL3z2vDgxUt0W3dWQOrprscmda2Y5pLsLg4GF+pI='"  # sha256("alert(1)")
REDCSS = "'sha256-FcQqt3aNlV7AZnGV4zkQRVeCeJOxbMPnQSx258L803E='"  # sha256("body{color:red}")


class HashBlock(unittest.TestCase):
    def test_empty_body(self):
        self.assertEqual(csp.hash_block(""), EMPTY)

    def test_known_vector(self):
        self.assertEqual(csp.hash_block("alert(1)"), ALERT1)


class CollectHashes(unittest.TestCase):
    def test_executable_script_hashed(self):
        scripts, _ = csp.script_and_style_hashes("<script>alert(1)</script>")
        self.assertEqual(scripts, [ALERT1])

    def test_module_type_hashed(self):
        scripts, _ = csp.script_and_style_hashes('<script type="module">alert(1)</script>')
        self.assertEqual(scripts, [ALERT1])

    def test_style_hashed(self):
        _, styles = csp.script_and_style_hashes("<style>body{color:red}</style>")
        self.assertEqual(styles, [REDCSS])

    def test_ld_json_skipped_quoted(self):
        scripts, _ = csp.script_and_style_hashes('<script type="application/ld+json">{"a":1}</script>')
        self.assertEqual(scripts, [])

    def test_ld_json_skipped_unquoted(self):
        # hugo --minify emits unquoted attrs; a type="..."-only matcher would misclassify this as executable
        scripts, _ = csp.script_and_style_hashes('<script type=application/ld+json>{"a":1}</script>')
        self.assertEqual(scripts, [])

    def test_identical_scripts_deduped(self):
        scripts, _ = csp.script_and_style_hashes("<script>alert(1)</script><script>alert(1)</script>")
        self.assertEqual(scripts, [ALERT1])

    def test_raw_text_first_close_tag_left_to_right(self):
        scripts, _ = csp.script_and_style_hashes("<script>alert(1)</script>x<script>alert(1)</script>")
        self.assertEqual(scripts, [ALERT1])  # two identical blocks, deduped, extracted non-overlapping


class BuildPolicy(unittest.TestCase):
    def test_directive_skeleton(self):
        policy = csp.build_policy([ALERT1], [REDCSS])
        self.assertIn("default-src 'none'", policy)
        self.assertIn(f"script-src {ALERT1}", policy)
        self.assertIn(f"style-src {REDCSS}", policy)
        self.assertIn("img-src 'self' data:", policy)
        self.assertIn("font-src data:", policy)
        self.assertIn("base-uri 'none'", policy)
        self.assertIn("form-action 'none'", policy)

    def test_no_double_quote(self):
        # the policy goes inside content="...", so it must never contain a double quote
        self.assertNotIn('"', csp.build_policy([ALERT1], [REDCSS]))


class Guard(unittest.TestCase):
    CLEAN = '<head><meta charset=utf-8></head><body><a href="/x">x</a><script>alert(1)</script></body>'

    def test_clean_page_no_violations(self):
        self.assertEqual(csp.find_violations(self.CLEAN), [])

    def test_style_attribute(self):
        self.assertTrue(csp.find_violations('<div style="color:red">x</div>'))

    def test_on_handler(self):
        self.assertTrue(csp.find_violations('<button onclick="go()">x</button>'))

    def test_javascript_url(self):
        self.assertTrue(csp.find_violations('<a href="javascript:void(0)">x</a>'))

    def test_javascript_url_entity_encoded(self):
        self.assertTrue(csp.find_violations('<a href="&#106;avascript:alert(1)">x</a>'))

    def test_external_executable_script(self):
        self.assertTrue(csp.find_violations('<script src="/app.js"></script>'))

    def test_style_string_inside_script_is_not_a_violation(self):
        # the literal "style=" lives in JS source, not a start-tag — must not trip the guard
        self.assertEqual(csp.find_violations('<script>var s="style=oops"</script>'), [])

    def test_javascript_string_inside_style_is_not_a_violation(self):
        self.assertEqual(csp.find_violations('<style>a::before{content:"javascript:"}</style>'), [])


class InjectMeta(unittest.TestCase):
    PAGE = "<head><meta charset=utf-8><script>alert(1)</script></head><body></body>"

    def test_meta_placed_immediately_after_charset(self):
        out = csp.inject_meta(self.PAGE)
        i = out.index("<meta charset=utf-8>") + len("<meta charset=utf-8>")
        self.assertTrue(out[i:].startswith('<meta http-equiv="Content-Security-Policy"'))

    def test_meta_lists_the_block_hash(self):
        out = csp.inject_meta(self.PAGE)
        self.assertIn(ALERT1, out)

    def test_missing_charset_raises(self):
        with self.assertRaises(ValueError):
            csp.inject_meta("<head><script>alert(1)</script></head>")


if __name__ == "__main__":
    unittest.main()
