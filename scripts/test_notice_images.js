#!/usr/bin/env node
// 消息中心「评论配图」解析回归：从生产 Swift 里抽 noticeListJS，用合成通知数据验证图片字段。
// 只跑本地 JS，不发网络请求（network requests=0）。
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict'), path = require('node:path');
const src = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinBridge+More.swift'), 'utf8');
const m = src.match(/static let noticeListJS = #"""\n([\s\S]*?)\n\s*"""/);
assert.ok(m, 'production noticeListJS required');
const body = m[1];

// 与 requestJS 前缀同口径的辅助函数
const first = o => (o && o.url_list && o.url_list[0]) || null;
const parse = t => { try { return JSON.parse(t) } catch (e) { return null } };
const q = s => new URLSearchParams(s).toString();

// 与生产 first() 同口径：字段是带 url_list 的对象
const fixture = {
  status_code: 0,
  max_time: 1700000000,
  has_more: false,
  notice_list_v2: [
    {
      nid_str: 'n-img', type: 31, create_time: 1700000000, aweme_id: 'a-1',
      comment: {
        comment: {
          text: '带图的评论',
          user: { nickname: '测试用户', avatar_thumb: { url_list: ['https://example.invalid/av'] }, sec_uid: 'sec-1' },
          image_list: [
            { medium_url: { url_list: ['https://example.invalid/m1'] }, origin_url: { url_list: ['https://example.invalid/o1'], width: 1080, height: 1920 } },
            { thumb_url: { url_list: ['https://example.invalid/t2'] } }
          ]
        },
        aweme: { aweme_id: 'a-1', video: { cover: { url_list: ['https://example.invalid/cover'] } } }
      }
    },
    {
      // 11-19 真机：一级评论的通知 parent_id = 作品 id（不是评论 id）
      nid_str: 'n-top', type: 31, create_time: 1699999998, aweme_id: 'a-3',
      comment: { parent_id: 'a-3', comment: { cid: 'c-top', aweme_id: 'a-3', text: '一级评论', user: { nickname: '甲' } },
                 aweme: { aweme_id: 'a-3' } }
    },
    {
      nid_str: 'n-sub', type: 31, create_time: 1699999997, aweme_id: 'a-4',
      comment: { parent_id: 'c-parent', comment: { cid: 'c-sub', reply_id: 'c-parent', aweme_id: 'a-4', text: '楼中楼', user: { nickname: '乙' } },
                 aweme: { aweme_id: 'a-4' } }
    },
    {
      nid_str: 'n-plain', type: 31, create_time: 1699999999,
      comment: {
        comment: { text: '纯文字评论', user: { nickname: '路人', avatar_thumb: { url_list: ['https://example.invalid/av2'] } } },
        aweme: { aweme_id: 'a-2', video: { cover: { url_list: ['https://example.invalid/cover2'] } } }
      }
    }
  ]
};
let calls = 0;
const req = async () => { calls++; return { s: 200, t: JSON.stringify(fixture) }; };

const context = { first, parse, q, req, console, markRead: '0', minTime: '0', maxTime: '0', group: '700' };
vm.createContext(context);
const run = () => vm.runInContext('(async () => {' + body + '})()', context);

let count = 0;
function test(name, fn) { return Promise.resolve().then(fn).then(() => { count++; console.log('PASS', name); }); }

(async () => {
  await test('带图评论通知解出缩略图地址（medium 优先、缺 medium 用 thumb）', async () => {
    const r = JSON.parse(await run());
    assert.equal(r.items.length, 4);
    assert.deepEqual(r.items[0].images, ['https://example.invalid/m1', 'https://example.invalid/t2']);
  });
  await test('一级评论通知：parent_id 是作品 id 时不当楼中楼（否则回复挂到作品 id 下，发了看不到）', async () => {
    const r = JSON.parse(await run());
    const top = r.items.find(x => x.cid === 'c-top'), sub = r.items.find(x => x.cid === 'c-sub');
    assert.equal(top.parentCid, null); assert.equal(top.action, '评论了你');
    assert.equal(sub.parentCid, 'c-parent'); assert.equal(sub.action, '回复了你的评论');
  });
  await test('无图评论通知 images 为空不报错', async () => {
    const r = JSON.parse(await run());
    assert.ok(!r.items[1].images || r.items[1].images.length === 0);
  });
  await test('原有字段不受影响（action/detail/cover/awemeID）', async () => {
    const r = JSON.parse(await run());
    assert.equal(r.items[0].action, '评论了你');
    assert.equal(r.items[0].detail, '带图的评论');
    assert.equal(r.items[0].cover, 'https://example.invalid/cover');
    assert.equal(r.items[0].awemeID, 'a-1');
  });
  console.log(`Notice images: ${count} synthetic tests passed; network requests=${calls}`);
})().catch(e => { console.error('FAIL', e.message); process.exit(1); });
