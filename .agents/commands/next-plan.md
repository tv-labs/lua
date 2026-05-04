---
description: Pick up the next ready plan file and ship it to a PR
agent: build
---

Find the next plan in `.agents/plans/` where `status: ready`. Order by id
(A0 before A1 before A2; A before B). Skip plans whose status is `blocked`,
`in-progress`, `review`, `merged`, or `deferred`.

Show me the plan summary first:

- id and title
- direction
- branch and base
- success criteria (as a checklist)
- estimated effort (from your read of the plan)

Then ask whether to proceed.

If I confirm, load the `ship-a-plan` skill and execute it on that plan file.

If there are no ready plans, list the plans grouped by status so I can see
the current state of the pipeline.
