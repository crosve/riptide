"""Generate the DB ERD as a draw.io file by introspecting the live database.

Reads pg_catalog (tables, columns, primary keys, foreign keys) and emits an
editable, uncompressed .drawio ERD grouped by domain. Regenerate after every
migration:

    GEN_ERD_DSN=postgresql://postgres:postgres@localhost:5432/riptide \
        uv run python scripts/gen_erd.py

The output is committed at diagrams/db/riptide-erd.drawio.
"""

import html
import os

import psycopg

DSN = os.getenv("GEN_ERD_DSN", "postgresql://postgres:postgres@localhost:5432/riptide")
OUT = os.getenv("GEN_ERD_OUT", "diagrams/db/riptide-erd.drawio")

# Column assignment + colour per domain. Tables not listed fall into "Other".
DOMAINS: list[tuple[str, list[str], tuple[str, str]]] = [
    ("Tenancy & Identity", ["tenants", "users", "teams", "team_members"], ("#dae8fc", "#6c8ebf")),
    ("Access Control", ["collections", "collection_grants", "api_keys"], ("#d5e8d4", "#82b366")),
    ("Content & Versioning", ["documents", "document_versions", "ingestion_jobs"], ("#ffe6cc", "#d79b00")),
    ("Chunks & Search", ["chunks", "chunk_embeddings", "embedding_models"], ("#e1d5e7", "#9673a6")),
    ("Audit", ["audit_log"], ("#f8cecc", "#b85450")),
]

TABLE_W = 250
COL_GAP = 150
ROW_H = 22
HEADER_H = 28
TABLE_GAP = 40
TOP_Y = 80
LEFT_X = 40

TYPE_SHORTEN = {
    "timestamp with time zone": "timestamptz",
    "character varying": "varchar",
    "double precision": "float8",
}


def fetch_schema(conn: psycopg.Connection):
    cur = conn.cursor()
    cur.execute(
        """
        SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid
        WHERE n.nspname = 'public' AND c.relkind = 'r'
          AND a.attnum > 0 AND NOT a.attisdropped
          AND c.relname <> 'alembic_version'
        ORDER BY c.relname, a.attnum
        """
    )
    columns: dict[str, list[tuple[str, str, bool]]] = {}
    for table, col, typ, notnull in cur.fetchall():
        typ = TYPE_SHORTEN.get(typ, typ)
        columns.setdefault(table, []).append((col, typ, notnull))

    cur.execute(
        """
        SELECT c.relname, a.attname
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (con.conkey)
        WHERE con.contype = 'p' AND n.nspname = 'public'
        """
    )
    pk: dict[str, set[str]] = {}
    for table, col in cur.fetchall():
        pk.setdefault(table, set()).add(col)

    cur.execute(
        """
        SELECT c.relname AS tbl, rc.relname AS reftbl,
               (SELECT array_agg(att.attname ORDER BY x.ord)
                  FROM unnest(con.conkey) WITH ORDINALITY AS x(attnum, ord)
                  JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = x.attnum) AS fk_cols
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class rc ON rc.oid = con.confrelid
        WHERE con.contype = 'f' AND n.nspname = 'public'
        """
    )
    fks: list[tuple[str, str]] = []           # (table, reftable) edges
    fk_cols: dict[str, set[str]] = {}         # fk columns per table (for markers)
    for tbl, reftbl, cols in cur.fetchall():
        fks.append((tbl, reftbl))
        for c in cols:
            fk_cols.setdefault(tbl, set()).add(c)
    return columns, pk, fk_cols, fks


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def build_xml(columns, pk, fk_cols, fks) -> str:
    cells: list[str] = []
    table_ids: dict[str, str] = {}
    assigned: set[str] = set()

    for col_idx, (domain, tables, (fill, stroke)) in enumerate(DOMAINS):
        x = LEFT_X + col_idx * (TABLE_W + COL_GAP)
        # domain header
        cells.append(
            f'<mxCell id="hdr{col_idx}" value="{esc(domain)}" '
            f'style="text;html=1;align=center;fontStyle=1;fontSize=14;fontColor={stroke};" '
            f'vertex="1" parent="1"><mxGeometry x="{x}" y="40" width="{TABLE_W}" height="26" as="geometry"/></mxCell>'
        )
        y = TOP_Y
        for table in tables:
            if table not in columns:
                continue
            assigned.add(table)
            tid = f"t_{table}"
            table_ids[table] = tid
            cols = columns[table]
            height = HEADER_H + len(cols) * ROW_H
            cells.append(
                f'<mxCell id="{tid}" value="{esc(table)}" '
                f'style="swimlane;html=1;fontStyle=1;fontSize=13;childLayout=stackLayout;'
                f'horizontal=1;startSize={HEADER_H};horizontalStack=0;resizeParent=1;'
                f'resizeParentMax=0;collapsible=0;marginBottom=0;'
                f'swimlaneFillColor=#ffffff;fillColor={fill};strokeColor={stroke};" '
                f'vertex="1" parent="1"><mxGeometry x="{x}" y="{y}" width="{TABLE_W}" height="{height}" as="geometry"/></mxCell>'
            )
            for i, (cname, ctype, notnull) in enumerate(cols):
                tags = []
                if cname in pk.get(table, set()):
                    tags.append("PK")
                if cname in fk_cols.get(table, set()) and cname != "tenant_id":
                    tags.append("FK")
                suffix = f"  [{', '.join(tags)}]" if tags else ""
                nn = "" if notnull else "?"
                label = f"{cname}{nn} : {ctype}{suffix}"
                is_key = "PK" in tags
                cells.append(
                    f'<mxCell id="{tid}_c{i}" value="{esc(label)}" '
                    f'style="text;html=1;align=left;verticalAlign=middle;spacingLeft=8;fontSize=11;'
                    f'{"fontStyle=1;" if is_key else ""}strokeColor=none;fillColor=none;" '
                    f'vertex="1" parent="{tid}"><mxGeometry y="{HEADER_H + i * ROW_H}" width="{TABLE_W}" height="{ROW_H}" as="geometry"/></mxCell>'
                )
            y += height + TABLE_GAP

    # any table not in a domain (future-proofing)
    leftover = [t for t in columns if t not in assigned]
    if leftover:
        x = LEFT_X + len(DOMAINS) * (TABLE_W + COL_GAP)
        y = TOP_Y
        for table in leftover:
            tid = f"t_{table}"
            table_ids[table] = tid
            cols = columns[table]
            height = HEADER_H + len(cols) * ROW_H
            cells.append(
                f'<mxCell id="{tid}" value="{esc(table)}" style="swimlane;html=1;fontStyle=1;startSize={HEADER_H};'
                f'fillColor=#f5f5f5;strokeColor=#666666;" vertex="1" parent="1">'
                f'<mxGeometry x="{x}" y="{y}" width="{TABLE_W}" height="{height}" as="geometry"/></mxCell>'
            )
            for i, (cname, ctype, notnull) in enumerate(cols):
                cells.append(
                    f'<mxCell id="{tid}_c{i}" value="{esc(cname + " : " + ctype)}" '
                    f'style="text;html=1;align=left;spacingLeft=8;fontSize=11;" vertex="1" parent="{tid}">'
                    f'<mxGeometry y="{HEADER_H + i * ROW_H}" width="{TABLE_W}" height="{ROW_H}" as="geometry"/></mxCell>'
                )
            y += height + TABLE_GAP

    for n, (tbl, reftbl) in enumerate(fks):
        if tbl not in table_ids or reftbl not in table_ids:
            continue
        selfref = tbl == reftbl
        style = (
            "edgeStyle=entityRelationEdgeStyle;fontSize=10;html=1;rounded=0;"
            "endArrow=ERone;startArrow=ERmany;strokeColor=#555555;"
        )
        if selfref:
            style += "exitX=1;exitY=0.25;entryX=1;entryY=0.75;"
        cells.append(
            f'<mxCell id="e{n}" style="{style}" edge="1" parent="1" '
            f'source="{table_ids[tbl]}" target="{table_ids[reftbl]}"><mxGeometry relative="1" as="geometry"/></mxCell>'
        )

    legend = (
        "Legend:  bold = primary key  ·  [PK]/[FK] column tags  ·  ? = nullable  ·  "
        "crow&#39;s-foot points to the referenced (one) side.  "
        "Every tenant-owned table carries tenant_id and is governed by RLS."
    )
    cells.append(
        f'<mxCell id="legend" value="{legend}" '
        f'style="text;html=1;align=left;fontSize=11;fillColor=#fff2cc;strokeColor=#d6b656;spacingLeft=8;" '
        f'vertex="1" parent="1"><mxGeometry x="{LEFT_X}" y="20" width="900" height="24" as="geometry"/></mxCell>'
    )
    cells.append(
        '<mxCell id="title" value="riptide — database ERD (generated from the live schema)" '
        'style="text;html=1;align=left;fontStyle=1;fontSize=18;" vertex="1" parent="1">'
        f'<mxGeometry x="{LEFT_X}" y="-10" width="900" height="28" as="geometry"/></mxCell>'
    )

    body = "\n        ".join(cells)
    return (
        '<mxfile host="app.diagrams.net">\n'
        '  <diagram id="riptide-erd" name="ERD">\n'
        '    <mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" '
        'tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" '
        'pageWidth="1600" pageHeight="2200" math="0" shadow="0">\n'
        "      <root>\n"
        '        <mxCell id="0"/>\n'
        '        <mxCell id="1" parent="0"/>\n'
        f"        {body}\n"
        "      </root>\n"
        "    </mxGraphModel>\n"
        "  </diagram>\n"
        "</mxfile>\n"
    )


def main() -> None:
    with psycopg.connect(DSN) as conn:
        columns, pk, fk_cols, fks = fetch_schema(conn)
    xml = build_xml(columns, pk, fk_cols, fks)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as fh:
        fh.write(xml)
    print(f"wrote {OUT}: {len(columns)} tables, {len(fks)} foreign keys")


if __name__ == "__main__":
    main()
