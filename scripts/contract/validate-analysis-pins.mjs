import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const enginePath = process.env.TOVIS_ANALYSIS_ENGINE
assert(enginePath, 'Set TOVIS_ANALYSIS_ENGINE to the target server checkout lib/consult/analysisEngine.ts before archiving.')
const engine = readFileSync(enginePath, 'utf8')
const service = readFileSync(resolve(here, '../../TovisKit/Sources/TovisKit/Consult/ConsultService.swift'), 'utf8')
const fixture = JSON.parse(readFileSync(resolve(here, '../../TovisKit/Tests/TovisKitTests/Fixtures/consultFlow.json'), 'utf8'))

function capture(source, pattern, label) {
  const matches = [...source.matchAll(pattern)]
  assert.equal(matches.length, 1, `Expected exactly one ${label} declaration`)
  return matches[0][1]
}

const serverSchema = Number(capture(engine, /^export const CONSULT_ANALYSIS_SCHEMA_VERSION = (\d+)\s*$/gm, 'server schema'))
const serverPrompt = capture(engine, /^export const CONSULT_ANALYSIS_PROMPT_VERSION = '([^']+)'\s*$/gm, 'server prompt')
const iosSchema = Number(capture(service, /^\s*public static let analysisSchemaVersion = (\d+)\s*$/gm, 'iOS schema'))
const iosPrompt = capture(service, /^\s*public static let analysisPromptVersion = "([^"]+)"\s*$/gm, 'iOS prompt')
assert.equal(iosSchema, serverSchema, 'iOS analysis schema differs from target server')
assert.equal(iosPrompt, serverPrompt, 'iOS analysis prompt differs from target server')
assert.equal(fixture.analysis.analysis.schemaVersion, serverSchema, 'Analysis fixture schema is stale')
assert.equal(fixture.analysis.analysis.promptVersion, serverPrompt, 'Analysis fixture prompt is stale')
console.log(`Analysis pins match target server: schema ${serverSchema}, ${serverPrompt}`)
