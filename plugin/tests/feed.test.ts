import { expect, mock, test } from 'claude-code/testing'
import type { On, SessionUsage } from 'claude-code'

const START = Date.parse('2026-10-11T12:00:00Z')
const MINUTE = 60_000

const usage = (over: Partial<SessionUsage> = {}): SessionUsage => ({
  startedAt: START,
  context: { tokens: 68_600, window: 1_000_000, percent: 7 },
  rateLimits: [
    { kind: 'five_hour', percentUsed: 2.3, resetsAt: new Date(START + 276 * MINUTE).toISOString() },
    { kind: 'seven_day', percentUsed: 76.4, resetsAt: new Date(START + 836 * MINUTE).toISOString() },
  ],
  cost: { usd: 206.512 },
  ...over,
})

type Written = { path: string; text: string }

// The test's hooks stand for the engine beneath the mod.
const answerUsage = (
  on: On,
  figures: SessionUsage,
  host: { surface?: 'desktop' | 'terminal'; written?: Written[] } = {},
) => {
  mock.env(on, { HOME: '/Users/t' })
  on('session.usage', () => ({ value: figures }))
  on('session.id', () => ({ value: 's1' }))
  on('session.root', () => ({ value: '/Users/t/project' }))
  on('session.surface', () => ({ value: host.surface ?? 'desktop' }))
  on('fs.write', (_, e) => {
    host.written?.push({ path: e.path, text: e.text })

    return { value: undefined }
  })
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
}

const START_INPUT = { cwd: '/tmp', surface: 'desktop', isInteractive: true } as const

const turn = (
  over: Partial<{ read: number; written: number; input: number; output: number; agentId: string }> = {},
) => ({
  answer: 'done',
  durationMs: 1000,
  isAborted: false,
  turnId: 't1',
  reason: 'answer' as const,
  ...(over.agentId === undefined ? {} : { agentId: over.agentId }),
  usage: {
    model: 'claude-opus-5-5',
    input_tokens: over.input ?? 100,
    output_tokens: over.output ?? 9_600,
    cache_read_input_tokens: over.read ?? 9_400,
    cache_creation_input_tokens: over.written ?? 500,
  },
})

const last = (written: Written[]) => JSON.parse(written.at(-1)?.text ?? '{}')

test('leaves a snapshot for the menu bar, marked active while a turn runs', async ($, on) => {
  const clock = mock.clock(on, { now: START })
  const written: Written[] = []
  answerUsage(on, usage(), { written })
  await $.session.start(START_INPUT)
  // Loading is not activity: nothing is written until the session does something.
  expect(written).toHaveLength(0)

  await $.turn.start({ text: 'go', turnId: 't1' })
  expect(JSON.parse(written.at(-1)?.text ?? '{}')).toMatchObject({
    cache: { active: true },
    // The reading the mod found as it loaded is of unknown age.
    limits_at: null,
  })

  // A reading arriving mid-turn is fresh, and the turn is still running.
  await clock.advance(MINUTE)
  const fresh = usage()
  await $.session.measure({
    context: fresh.context,
    rateLimits: fresh.rateLimits,
    cost: fresh.cost,
    changed: ['rateLimits'],
  })
  expect(JSON.parse(written.at(-1)?.text ?? '{}')).toMatchObject({
    cache: { active: true },
    limits_at: (START + MINUTE) / 1000,
  })

  await clock.advance(MINUTE)
  await $.turn.complete(turn())

  expect(written.at(-1)?.path).toBe('/Users/t/Library/Caches/CacheCue/s1.json')
  expect(JSON.parse(written.at(-1)?.text ?? '{}')).toEqual({
    v: 1,
    source: 'desktop',
    session_id: 's1',
    cwd: '/Users/t/project',
    cache: {
      turn_hit: 94,
      avg_hit: 94,
      expires_at: (START + 62 * MINUTE) / 1000,
      active: false,
    },
    limits: {
      five_hour: { used: 2.3, resets_at: (START + 276 * MINUTE) / 1000 },
      seven_day: { used: 76.4, resets_at: (START + 836 * MINUTE) / 1000 },
    },
    limits_at: (START + MINUTE) / 1000,
    context: { tokens: 68_600, output: 9_600, window: 1_000_000, percent: 7 },
    cost_usd: 206.512,
    updated_at: (START + 2 * MINUTE) / 1000,
  })
})

test('writes no snapshot in a terminal, where the status line command does', async ($, on) => {
  mock.clock(on, { now: START })
  const written: Written[] = []
  answerUsage(on, usage(), { surface: 'terminal', written })
  await $.session.start({ ...START_INPUT, surface: 'terminal' })
  await $.turn.complete(turn())

  expect(written).toHaveLength(0)
})

test('a failed snapshot write does not cost the session its turn', async ($, on) => {
  mock.clock(on, { now: START })
  mock.env(on, { HOME: '/Users/t' })
  const logged: string[] = []
  on('session.usage', () => ({ value: usage() }))
  on('session.id', () => ({ value: 's1' }))
  on('session.root', () => ({ value: '/Users/t/project' }))
  on('session.surface', () => ({ value: 'desktop' }))
  on('fs.write', () => ({ deny: 'disk full' }))
  on('ui.log', (_, e) => {
    logged.push(e.text)

    return { value: undefined }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  await $.session.start(START_INPUT)

  expect(await $.turn.complete(turn())).toMatchObject({ text: 'done' })
  expect(logged.join('\n')).toContain('snapshot not written')
})

test('averages over turns, ignores subagents, and counts expiry from the last write', async ($, on) => {
  const clock = mock.clock(on, { now: START })
  const written: Written[] = []
  answerUsage(on, usage(), { written })
  await $.session.start(START_INPUT)

  // Turn 1 writes the cache and reads nothing: 0% hit.
  await $.turn.complete(turn({ read: 0, written: 900, input: 100 }))
  expect(last(written).cache).toMatchObject({ turn_hit: 0, avg_hit: 0, expires_at: (START + 60 * MINUTE) / 1000 })
  await clock.advance(50 * MINUTE)
  // A subagent's turn must not move the main conversation's figures.
  const before = written.length
  await $.turn.complete(turn({ read: 0, written: 50_000, input: 0, agentId: 'a1' }))
  expect(written).toHaveLength(before)
  // Turn 2 only reads: 100% this turn, 3000/4000 overall, and no new write to count from.
  await $.turn.complete(turn({ read: 3_000, written: 0, input: 0 }))
  expect(last(written).cache).toMatchObject({ turn_hit: 100, avg_hit: 75, expires_at: (START + 60 * MINUTE) / 1000 })
})

test('session.measure replaces the figures', async ($, on) => {
  mock.clock(on, { now: START })
  const written: Written[] = []
  answerUsage(on, usage(), { written })
  await $.session.start(START_INPUT)
  const next = usage({
    context: { tokens: 181_000, window: 200_000, percent: 91 },
    rateLimits: [{ kind: 'five_hour', percentUsed: 95, resetsAt: new Date(START + 25 * MINUTE).toISOString() }],
    cost: { usd: 3.5 },
  })
  await $.session.measure({
    context: next.context,
    rateLimits: next.rateLimits,
    cost: next.cost,
    changed: ['context', 'rateLimits', 'cost'],
  })

  expect(last(written)).toMatchObject({
    limits: { five_hour: { used: 95, resets_at: (START + 25 * MINUTE) / 1000 } },
    context: { tokens: 181_000, window: 200_000, percent: 91 },
    cost_usd: 3.5,
  })
  expect(last(written).limits.seven_day).toBeUndefined()
})

test('an account that is told no limits leaves them out, not zeros that look like data', async ($, on) => {
  mock.clock(on, { now: START })
  const written: Written[] = []
  answerUsage(on, usage({ context: { window: 200_000 }, rateLimits: [], cost: undefined }), { written })
  await $.session.start(START_INPUT)
  await $.turn.start({ text: 'go', turnId: 't1' })

  expect(last(written)).toMatchObject({
    limits: {},
    limits_at: null,
    context: { tokens: 0, window: 200_000, percent: null },
    cost_usd: null,
    cache: { turn_hit: null, avg_hit: null, expires_at: null, active: true },
  })
})
