#!/usr/bin/env python3
"""Read-only audit of every canonical production page, sitemap and crawler rules."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.robotparser import RobotFileParser
import json
import re
import subprocess
import xml.etree.ElementTree as ET

from check_slowth import Document, check_seo
from render_slowth import BASE, LOCALES, url


def fetch(target):
    with TemporaryDirectory(prefix='slowth-seo-') as directory:
        headers=Path(directory)/'headers'
        result=subprocess.run(
            ['curl','--silent','--show-error','--fail','--max-time','30',
             '--retry','2','--dump-header',str(headers),'--write-out','\n%{json}',target],
            capture_output=True,text=True,check=True)
        body,metadata=result.stdout.rsplit('\n',1)
        status=json.loads(metadata)
        assert status['http_code']==200,(target,status['http_code'])
        assert status['url_effective']==target,(target,'unexpected redirect')
        for line in headers.read_text().splitlines():
            if line.lower().startswith('x-robots-tag:'):
                assert not set(re.split(r'[\s,:]+',line.lower())) & {'noindex','none'},(target,line)
        return body


def main():
    expected={url(locale,page) for locale in LOCALES for page in ['index','support','privacy']}
    sitemap=ET.fromstring(fetch(BASE+'sitemap.xml'))
    locations=[node.text for node in sitemap.iter('{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]
    assert len(locations)==len(expected) and set(locations)==expected,'Live sitemap mismatch'
    robots=RobotFileParser()
    robots.parse(fetch(BASE+'robots.txt').splitlines())
    assert BASE+'sitemap.xml' in (robots.site_maps() or []),'Missing Sitemap directive'
    for target in expected:
        assert robots.can_fetch('Googlebot',target),(target,'Googlebot disallowed')
    def check(item):
        locale,page=item;target=url(locale,page)
        check_seo(Document(fetch(target)),locale,page,target)
        return target
    items=[(locale,page) for locale in LOCALES for page in ['index','support','privacy']]
    with ThreadPoolExecutor(max_workers=6) as pool:
        checked=list(pool.map(check,items))
    print(f'Passed live audit: {len(checked)} HTTP 200 pages; canonical, hreflang, robots, SoftwareApplication, FAQPage and sitemap.')
    print('This checks HTTP responses, not Google indexing or access from verified Googlebot IPs.')


if __name__=='__main__':
    main()
