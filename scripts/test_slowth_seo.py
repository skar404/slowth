"""Regression cases that the old metadata checks silently accepted."""
import unittest
import json
from check_slowth import Document, check_seo
from render_slowth import SITE, faq_pairs


class SEOTests(unittest.TestCase):
    def setUp(self):
        self.html=(SITE/'index.html').read_text()

    def check(self,html):
        check_seo(Document(html),'en','index','test')

    def test_duplicate_alternate_rejected(self):
        with self.assertRaisesRegex(AssertionError,'duplicate hreflang'):
            self.check(self.html.replace('</head>','<link rel="alternate" hreflang="en" href="https://slowth.app/"></head>'))

    def test_robot_directive_variants_rejected(self):
        for name,content in [('robots','NOINDEX, follow'),('Googlebot','none'),('robots','max-snippet:20, noindex')]:
            with self.subTest(name=name,content=content), self.assertRaisesRegex(AssertionError,'indexing blocked'):
                self.check(self.html.replace('</head>',f'<meta name="{name}" content="{content}"></head>'))

    def test_wrong_download_and_price_rejected(self):
        for old,new in [('"price": "0"','"price": "1"'),('https://apps.apple.com/app/id6764140763','https://example.com/app')]:
            with self.subTest(old=old), self.assertRaises(AssertionError):
                self.check(self.html.replace(old,new))

    def test_edge_script_does_not_hide_or_duplicate_schema(self):
        self.check(self.html.replace('</body>', '<script src="/cdn-cgi/email.js"></script></body>'))

    def test_faq_must_match_visible_answer(self):
        body=Document(self.html).scripts[1][1]
        schema=json.loads(body)
        schema['mainEntity'][0]['acceptedAnswer']['text']='Not the visible answer'
        with self.assertRaisesRegex(AssertionError,'FAQ differs'):
            self.check(self.html.replace(body,json.dumps(schema)))

    def test_faq_text_decodes_entities_and_preserves_inline_spacing(self):
        document='<section id="faq"><details><summary>Can I block <b>Reels</b>?</summary><p>Yes &amp; no.</p><p>Read <a href="support.html">support</a>.</p></details></section><details><summary>Language chooser</summary></details>'
        self.assertEqual(faq_pairs(document),[{'question':'Can I block Reels?','answer':'Yes & no. Read support.'}])

    def test_excluded_languages_remain_crawlable(self):
        for locale in ['fil','pcm','yue']:
            doc=Document((SITE/locale/'index.html').read_text())
            check_seo(doc,locale,'index',locale)
            self.assertEqual(doc.select('html')[0]['lang'],locale)
            self.assertTrue(any(a.get('lang')==locale for a in doc.select('a')))


if __name__=='__main__':
    unittest.main()
