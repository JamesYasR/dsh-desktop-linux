#!/usr/bin/env node
// 从 GitHub Releases API 的 JSON 生成「历史版本目录」versions.json。
//
// 输入（stdin）兼容两种形态：
//   1. 单个 releases 数组：`gh api repos/OWNER/REPO/releases`
//   2. 页数组的数组：`gh api --paginate --slurp ...`（每一页是一个数组，外面再包一层）
// 输出（stdout）：目录 JSON，结构见 buildIndex 的返回值。
//
// 目录字段全部来自各归档 release 正文里的 HTML 注释（`<!-- 字段: 值 -->`），不读 release
// 标题或资产列表 —— 注释是发布流程唯一写入的事实来源，缺字段的 release 直接跳过并在 stderr
// 说明原因，宁可目录少一条，也不要写出字段不全的条目让客户端误判。
//
// 只依赖 node 内置模块，便于在 CI 的裸 node 上直接跑。

import { pathToFileURL } from 'node:url'

/** 未设置 GITHUB_REPOSITORY 时的兜底仓库（本地跑、仓库改名前的历史数据都用它）。 */
const DEFAULT_REPOSITORY = 'JamesYasR/dsh-desktop-linux'

/** 归档 release 的 tag 前缀；滚动 feed（linux-latest）不匹配，天然被排除。 */
const ARCHIVE_TAG_PATTERN = /^dsh-v/

/** 归档 release 正文里必须具备的注释字段（缺一即跳过该 release）。 */
const REQUIRED_FIELDS = [
  'build-version',
  'build-number',
  'upstream-ref',
  'source-commit',
  'session-format',
  'session-query-schema',
  'storage-schema',
]

/** 可选字段组：三个字段全缺则整组省略，部分存在则视为残缺（跳过）。 */
const OPTIONAL_GROUPS = [
  { key: 'appImage', fields: ['appimage', 'appimage-sha512', 'appimage-size'] },
  { key: 'deb', fields: ['deb', 'deb-sha512', 'deb-size'] },
]

/** 需要按整数解析的字段；值不是纯数字时按缺失处理。 */
const NUMERIC_FIELDS = new Set([
  'build-number',
  'session-format',
  'session-query-schema',
  'storage-schema',
  'appimage-size',
  'deb-size',
])

/**
 * 把任意层级的嵌套数组摊平成一维。
 * `gh api --slurp` 给的是 `[[release, ...], [release, ...]]`。
 *
 * @param {unknown} input 原始 JSON（页数组/对象数组/混合）
 * @returns {Array<Record<string, unknown>>} 只含对象的扁平数组
 */
export function flattenReleases(input) {
  const out = []
  if (!Array.isArray(input)) return out
  for (const item of input) {
    if (Array.isArray(item)) out.push(...flattenReleases(item))
    else if (item && typeof item === 'object') out.push(/** @type {Record<string, unknown>} */ (item))
  }
  return out
}

/**
 * 从 release 正文里解析 HTML 注释字段。
 * 形如 `<!-- build-version: 0.2.1-alpha.4 -->`，同名注释以第一条为准。
 *
 * @param {unknown} body release 正文
 * @returns {Record<string, string>} 字段名 → 去空白后的字符串值
 */
export function parseReleaseComments(body) {
  /** @type {Record<string, string>} */
  const fields = {}
  if (typeof body !== 'string') return fields
  for (const match of body.matchAll(/<!--\s*([A-Za-z0-9_-]+)\s*:\s*([\s\S]*?)\s*-->/g)) {
    const name = match[1]
    if (!(name in fields)) fields[name] = match[2].trim()
  }
  return fields
}

/**
 * 取一个字段并做基本校验：空字符串、非整数的数字字段都当作缺失。
 *
 * @param {Record<string, string>} fields 注释字段表
 * @param {string} name 字段名
 * @returns {string | undefined} 合法时返回字符串，否则 undefined
 */
function readField(fields, name) {
  const value = fields[name]
  if (typeof value !== 'string' || value === '') return undefined
  if (NUMERIC_FIELDS.has(name) && !/^[0-9]+$/.test(value)) return undefined
  return value
}

/**
 * 把一条归档 release 转成目录条目。
 *
 * @param {Record<string, unknown>} release GitHub Releases API 的单个 release
 * @param {string} repository `owner/repo`
 * @returns {{ entry?: Record<string, unknown>, missing?: string }} 成功给 entry，缺字段给 missing
 */
function buildVersionEntry(release, repository) {
  const tag = typeof release.tag_name === 'string' ? release.tag_name : ''
  const fields = parseReleaseComments(release.body)
  const missing = []

  for (const name of REQUIRED_FIELDS) {
    if (readField(fields, name) === undefined) missing.push(name)
  }
  // 客户端要求 publishedAt 是非空字符串，所以没有它的 release 宁可整条跳过。
  const publishedAt = typeof release.published_at === 'string' && release.published_at !== ''
    ? release.published_at : undefined
  if (publishedAt === undefined) missing.push('published_at')

  /** @type {Record<string, unknown>} */
  const optional = {}
  for (const group of OPTIONAL_GROUPS) {
    const present = group.fields.filter((name) => readField(fields, name) !== undefined)
    if (present.length === 0) continue // 整组没有 → 整个字段省略
    const absent = group.fields.filter((name) => readField(fields, name) === undefined)
    if (absent.length > 0) {
      missing.push(absent[0]) // 只写了一半的组视为残缺
      continue
    }
    optional[group.key] = {
      file: readField(fields, group.fields[0]),
      sha512: readField(fields, group.fields[1]),
      size: Number(readField(fields, group.fields[2])),
    }
  }

  if (missing.length > 0) return { missing: missing[0] }

  /** @type {Record<string, unknown>} */
  const entry = {
    version: readField(fields, 'build-version'),
    upstreamRef: readField(fields, 'upstream-ref'),
    buildNumber: Number(readField(fields, 'build-number')),
    feedUrl: `https://github.com/${repository}/releases/download/${tag}`,
    releaseUrl: `https://github.com/${repository}/releases/tag/${tag}`,
    publishedAt,
    sessionFormatVersion: Number(readField(fields, 'session-format')),
    sessionQuerySchemaVersion: Number(readField(fields, 'session-query-schema')),
    storageSchemaVersion: Number(readField(fields, 'storage-schema')),
  }
  if (optional.appImage) entry.appImage = optional.appImage
  if (optional.deb) entry.deb = optional.deb
  return { entry }
}

/**
 * 自然版本比较（等价于 `sort -V`）：数字段按数值比，非数字段按字典序，短的一边小。
 * 只用于挑 `current` 与同发布时间下的次序，不做 semver 的完整语义校验。
 *
 * @param {string} a 版本号
 * @param {string} b 版本号
 * @returns {number} 负数表示 a < b
 */
export function compareVersions(a, b) {
  const tokenize = (value) => String(value ?? '').match(/\d+|\D+/g) ?? []
  const ta = tokenize(a)
  const tb = tokenize(b)
  const length = Math.max(ta.length, tb.length)
  for (let i = 0; i < length; i += 1) {
    const x = ta[i]
    const y = tb[i]
    if (x === undefined) return -1
    if (y === undefined) return 1
    const xNum = /^\d+$/.test(x)
    const yNum = /^\d+$/.test(y)
    if (xNum && yNum) {
      const diff = Number(x) - Number(y)
      if (diff !== 0) return diff
    } else if (xNum !== yNum) {
      return xNum ? 1 : -1 // 数字段比字母段大：0.2.1 > 0.2.1-alpha
    } else if (x !== y) {
      return x < y ? -1 : 1
    }
  }
  return 0
}

/**
 * 构建完整的版本目录。
 *
 * @param {unknown} input Releases API 的原始 JSON（页数组或对象数组）
 * @param {string} [repository] `owner/repo`，默认取 GITHUB_REPOSITORY 或兜底仓库
 * @returns {{
 *   schemaVersion: number,
 *   generatedAt: string,
 *   current: string | null,
 *   versions: Array<Record<string, unknown>>,
 * }} 可直接 JSON.stringify 的目录对象
 */
export function buildIndex(input, repository = process.env.GITHUB_REPOSITORY || DEFAULT_REPOSITORY) {
  /** @type {Array<Record<string, unknown>>} */
  const versions = []
  for (const release of flattenReleases(input)) {
    if (release.draft === true) continue // 草稿还没发布，不进目录
    const tag = typeof release.tag_name === 'string' ? release.tag_name : ''
    if (!ARCHIVE_TAG_PATTERN.test(tag)) continue // linux-latest 等滚动 release 不是历史版本
    const { entry, missing } = buildVersionEntry(release, repository)
    if (!entry) {
      process.stderr.write(`skip ${tag || '(无 tag)'}: missing ${missing}\n`)
      continue
    }
    versions.push(entry)
  }

  // 从新到旧；同一发布时间（同一次构建归档）时版本号大的在前。
  versions.sort((a, b) => {
    const ta = Date.parse(String(a.publishedAt ?? '')) || 0
    const tb = Date.parse(String(b.publishedAt ?? '')) || 0
    if (tb !== ta) return tb - ta
    return compareVersions(String(b.version ?? ''), String(a.version ?? ''))
  })

  let current = null
  for (const entry of versions) {
    const version = String(entry.version ?? '')
    if (current === null || compareVersions(version, current) > 0) current = version
  }

  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    current,
    versions,
  }
}

/** 读 stdin、生成目录、写 stdout；解析失败直接抛错退出（宁可响亮失败）。 */
async function main() {
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  const text = Buffer.concat(chunks).toString('utf8')
  const index = buildIndex(JSON.parse(text))
  process.stdout.write(`${JSON.stringify(index, null, 2)}\n`)
}

// 只有被直接执行时才读 stdin；被 import 做单测时不产生副作用。
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`versions-index.mjs: ${error?.stack ?? error}\n`)
    process.exitCode = 1
  })
}
