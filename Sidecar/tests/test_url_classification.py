"""Image-search detection matches real hostnames, not substrings (CodeQL py/incomplete-url-substring-sanitization)."""

import pytest

from jarvis.tools import host_is, is_image_search


@pytest.mark.parametrize("url", [
    "https://www.google.com/search?q=cats&tbm=isch",
    "https://www.google.co.uk/search?q=cats&udm=2",
    "https://google.es/search?q=gatos&udm=2",
    "https://www.bing.com/images/search?q=cats",
    "https://duckduckgo.com/?q=cats&iax=images",
])
def test_image_searches_are_recognised(url):
    assert is_image_search(url)


@pytest.mark.parametrize("url", [
    "https://google.evil.com/search?tbm=isch",
    "https://mygoogle.com/?tbm=isch",
    "https://notbing.com/imagesx?q=cats",
    "https://bing.com.evil.net/imagesx?q=cats",
    "https://www.google.com/search?q=cats",
])
def test_lookalike_hosts_and_plain_searches_are_not(url):
    assert not is_image_search(url)


def test_host_is_matches_the_site_and_its_subdomains_only():
    assert host_is("bing.com", "bing.com") and host_is("www.bing.com", "bing.com")
    assert not host_is("notbing.com", "bing.com") and not host_is("bing.com.evil.net", "bing.com")
