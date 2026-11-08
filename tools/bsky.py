#!/usr/bin/env python3
"""Test-account helper. Only ever touches the two test accounts' own records.
usage: bsky.py setup | cleanup"""
import json, os, sys, urllib.request, urllib.error, datetime
kv = {}
for l in open(os.path.expanduser('~/.config/tinysky/credentials')):
    l = l.strip()
    if l and not l.startswith('#') and '=' in l:
        k, v = l.split('=', 1); kv[k] = v
H = 'https://bsky.social/xrpc/'
def call(path, body=None, tok=None):
    r = urllib.request.Request(H + path, data=json.dumps(body).encode() if body is not None else None,
        headers={'Content-Type': 'application/json', 'User-Agent': 'thimble-test', **({'Authorization': 'Bearer ' + tok} if tok else {})})
    return json.load(urllib.request.urlopen(r, timeout=30))
def login(a):
    s = call('com.atproto.server.createSession', {'identifier': kv[f'TINYSKY_{a}_HANDLE'], 'password': kv[f'TINYSKY_{a}_APP_PASSWORD']})
    return s['accessJwt'], s['did']
now = lambda: datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
def rec(t, d, c, r): return call('com.atproto.repo.createRecord', {'repo': d, 'collection': c, 'record': {'$type': c, 'createdAt': now(), **r}}, t)
def records(t, d, c):
    return call(f'com.atproto.repo.listRecords?repo={d}&collection={c}&limit=100', None, t).get('records', [])
TEST_COLLS = ['app.bsky.feed.post', 'app.bsky.feed.like', 'app.bsky.feed.repost', 'app.bsky.graph.block']
ta, da = login('A'); tb, db = login('B')
if sys.argv[1] == 'setup':
    for t, d, o in ((ta, da, db), (tb, db, da)):
        if not any(r['value'].get('subject') == o for r in records(t, d, 'app.bsky.graph.follow')):
            rec(t, d, 'app.bsky.graph.follow', {'subject': o})
    rec(tb, db, 'app.bsky.feed.post', {'text': 'Thimble test post from B, please ignore'})
    print('setup ok')
elif sys.argv[1] == 'cleanup':
    n = 0
    for t, d in ((ta, da), (tb, db)):
        for c in TEST_COLLS:
            for r in records(t, d, c):
                call('com.atproto.repo.deleteRecord', {'repo': d, 'collection': c, 'rkey': r['uri'].rsplit('/', 1)[1]}, t); n += 1
    for t, d in ((ta, da), (tb, db)):
        svc = [x for x in json.load(urllib.request.urlopen(urllib.request.Request('https://plc.directory/' + d, headers={'User-Agent': 'thimble-test'}), timeout=20))['service'] if x['id'] == '#atproto_pds'][0]['serviceEndpoint'] + '/xrpc/'
        hdr = {'Authorization': 'Bearer ' + t, 'User-Agent': 'thimble-test', 'Content-Type': 'application/json', 'atproto-proxy': 'did:web:api.bsky.chat#bsky_chat'}
        cs = json.load(urllib.request.urlopen(urllib.request.Request(svc + 'chat.bsky.convo.listConvos?limit=50', headers=hdr), timeout=20)).get('convos', [])
        for c in cs:
            urllib.request.urlopen(urllib.request.Request(svc + 'chat.bsky.convo.leaveConvo', data=json.dumps({'convoId': c['id']}).encode(), headers=hdr), timeout=20); n += 1
    print('deleted', n, 'records')
