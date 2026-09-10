# bot_army_dispatcher

The army's alert / incident dispatcher. Subscribes to the firehose of
things going wrong and turns them into routed, deduplicated, escalated
work — with a learning layer that improves routing over time.

## Subjects

| Subject | Direction | Purpose |
| --- | --- | --- |
| `alerts.>` | subscribe | all alert events |
| `dlq.>` | subscribe | dead-letter queue events |
| `risk.critical` | subscribe | critical risk signals |
| `bridge.incident.>` | subscribe | incident events from the bridge |
| `bot.army.health.stale` / `.recovered` | subscribe | stale-bot alerts |
| `dispatcher.system.health.digest.query` | request | system-health digest |
| `factory.fixer.request` | request | trigger a fixer run |
| `system.health` | publish | health pulse |

## Architecture

- `BotArmyDispatcher.NATS.Consumer` — registrations + handlers
- Incident store (Ecto) + risk scoring, dedup and escalation logic
- `UserLearning` + report generator / feedback analyzer / insights
  extractor — the learning layer (queries use `CircuitBreakerRepo`;
  reads are raw, writes are tuples)

## Development

```sh
mix deps.get
mix test
make publish-release   # OTP release tarball
```

`config/runtime.exs` reads `NATS_HOST` / `NATS_PORT` at boot via
`ConfigLoader` so releases never bake in the dev broker.