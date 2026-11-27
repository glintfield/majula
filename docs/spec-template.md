# Title of the design

> Copy this file to `docs/design/<job>-<kebab-title>.md` (e.g. `2.1-storage.md`) and replace every
> _italic_ prompt. Write "None" rather than deleting a section. Spikes (e.g. job 1.6) and steps
> marked _(no design doc)_ skip this template. Delete this note.

- Status: _Draft, Accepted, or Superseded by another design_
- Owner: _who drives this design_
- Date: _YYYY-MM-DD_
- Roadmap job: _N.N Name, with a link to its Outpost job_

## Context

_What exists today, and why this design is needed now._

## Goals

- _What this design must achieve._

## Non-goals

- _What it deliberately leaves out, and why._

## Requirements from Outpost

_What the capability must do, and what Outpost learned the hard way. Outpost's tests are evidence of
a requirement, not a suite to port. For a capability new in Majula, say so and take requirements
from the roadmap._

| Requirement                   | Evidence                               |
| ----------------------------- | -------------------------------------- |
| _What the capability must do_ | _Outpost design doc, incident or test_ |

## Design

_The design, from scratch._

### Data model

_Records added or changed, with their ID prefixes (ADR 0006). Records carry no tenant or owner
columns: a server serves one person. Name the commands and approvals that record the acting device
(I11). Say which fields are columns and which are JSON, and give each list query's order key and
index (ADR 0008)._

### API and contract changes

_RPCs, events, schema, CLI and config changes, and their compatibility._

## Alternatives

_At least one alternative to Outpost's design, each weighed against it and against the chosen
design. For a capability new in Majula, at least one alternative to the chosen design._

## Reuse

_What Outpost design or code is adopted, and why it's the best option found. "It already works"
isn't a reason on its own. "None" is a valid answer._

| Adopted from Outpost     | Why it's the best option |
| ------------------------ | ------------------------ |
| _Design or code adopted_ | _Why, on merit_          |

## Security

_Fill in against `docs/threat-model.md`, citing its IDs._

### Boundaries and attackers

_One row per §5 matrix cell the design touches. Take the invariants and R-IDs from the cell, and
name any T2.n capability the design must refuse._

| Cell      | Invariants | How the design keeps them |
| --------- | ---------- | ------------------------- |
| _T3 × B1_ | _I8, I9_   | _How, per invariant_      |

### Assets

_One row per A-ID the design stores, reads, sends or grants._

| Asset | What the design does with it             |
| ----- | ---------------------------------------- |
| _A3_  | _How it's stored, read, sent or granted_ |

### Anti-goal invariants

_Fill in every row. "Not touched" needs a reason._

| Invariant                       | How the design keeps it |
| ------------------------------- | ----------------------- |
| I1 Fail closed                  | _How_                   |
| I2 Exactly as approved          | _How_                   |
| I3 Declared scope               | _How_                   |
| I4 Escape corpus                | _How_                   |
| I5 Bypass is the only exception | _How_                   |

### Threat model changes

_New assets, boundaries, attackers, invariants or residual risks, with their new IDs. Append them
to `docs/threat-model.md` in this PR, or write "None"._

### Residual risk

_One line: the R-IDs this design leaves standing or closes, and any new risk it accepts._

## Testing

_What proves the design works, and any T2.n escape it adds to the corpus._

## Rollout

_Migrations, flags, ordering with other jobs, and how to back out._

## Open questions

- _Anything still undecided, and who decides it._

## Related ADRs

- _Links into `docs/adr/`, and any ADR this design needs written._
