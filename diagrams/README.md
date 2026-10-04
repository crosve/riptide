# diagrams

draw.io diagrams for riptide. The folder layout **mirrors the codebase module
structure** so a diagram lives next to the concept it documents.

## Layout

```
diagrams/
  system/            # cross-cutting, whole-architecture diagrams (not tied to one module)
    riptide-ingestion-pipeline.drawio
  db/                # database architecture
    riptide-erd.drawio          # full ERD (generated — see below)
    riptide-data-model.drawio   # conceptual model + security/permission notes (hand-authored)
  app/
    routers/         # HTTP API / endpoint flow diagrams
    services/        # business logic, incl. the ingestion pipeline
    core/            # config, settings, shared infrastructure
    worker/          # arq worker / queue / job flow diagrams
    models/          # data models, schemas, ERDs
```

As new modules are added under `app/`, add a matching folder here.

## The DB ERD is generated

`diagrams/db/riptide-erd.drawio` is produced from the live schema — **do not hand-edit it**.
Regenerate after every migration:

```bash
GEN_ERD_DSN=postgresql://postgres:postgres@localhost:5432/riptide \
  uv run python scripts/gen_erd.py
```

`riptide-data-model.drawio` is the opposite: a curated, hand-authored explainer of
the entities and the permission/clearance/ACL model. Edit it by hand when the
model's intent changes.

## Conventions

- **One concern per file.** Name files kebab-case after what they depict:
  `riptide-ingestion-pipeline.drawio`, `job-queue-flow.drawio`.
- **Place by scope.** A diagram about a single module goes in that module's
  folder; a diagram spanning multiple modules goes in `system/`.
- **Format.** Keep source as editable `.drawio` (open at [app.diagrams.net](https://app.diagrams.net)
  or the VS Code Draw.io Integration extension). If you export an image for docs,
  commit the `.drawio` alongside it so it stays editable.
- **Keep it current.** Update the diagram in the same change that alters the
  behavior it describes.
