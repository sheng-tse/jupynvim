#!/usr/bin/env python3
"""
Writes widgets_gallery_saved.ipynb next to this file: the widget gallery
(widgets_gallery.ipynb) run by nbclient without its ipympl cell, which saves
the standard widget state in the notebook, as another tool saves one. A spec
can then check that jupynvim shows such a notebook with no kernel.

Run by hand, never by the suite, inside the test env with the test kernel's
python:

  bash -c 'source tests/lib/test_env.sh; cd tests/fixtures && "$JNV_KERNEL_PYTHON" make_widgets_saved.py'

The notebook is written compact (no indentation, sorted keys): the saved
widget state alone is about 360 KB, and indented JSON would take the fixture
past its 400 KB budget. It is written to a temporary name next to the target,
read back and validated, and renamed into place, so an interrupted run never
leaves a truncated fixture.
"""
import json
import os
import sys

import nbclient
import nbformat

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "widgets_gallery.ipynb")
DST = os.path.join(HERE, "widgets_gallery_saved.ipynb")
STATE_MIME = "application/vnd.jupyter.widget-state+json"
VIEW_MIME = "application/vnd.jupyter.widget-view+json"


def fail(msg):
    print(f"make_widgets_saved: {msg}", file=sys.stderr)
    sys.exit(1)


def view_id(output):
    data = output.get("data") or {}
    return data.get(VIEW_MIME, {}).get("model_id")


def main():
    nb = nbformat.read(SRC, as_version=4)
    nb.cells = [c for c in nb.cells
                if not (c.cell_type == "code" and c.source.startswith("# W:ipympl"))]
    client = nbclient.NotebookClient(nb, kernel_name="python3", timeout=180,
                                     store_widget_state=True)
    nb = client.execute()

    block = (nb.metadata.get("widgets") or {}).get(STATE_MIME)
    if not block:
        fail("the executed notebook has no widget state")
    state = block["state"]

    views = [view_id(o) for c in nb.cells if c.cell_type == "code" for o in c.outputs]
    views = [v for v in views if v]
    if not views:
        fail("no cell shows a widget view")
    unsaved = [v for v in views if v not in state]
    if unsaved:
        fail(f"views without a saved state entry: {unsaved}")

    out_cells = [c for c in nb.cells if c.source.startswith("# W:output")]
    if len(out_cells) != 1:
        fail("expected exactly one # W:output cell")
    out_views = [view_id(o) for o in out_cells[0].outputs if view_id(o)]
    if not out_views:
        fail("the # W:output cell shows no Output widget")
    outs = state[out_views[0]]["state"].get("outputs") or []
    texts = "".join(o.get("text", "") for o in outs if o.get("output_type") == "stream")
    if "printed inside an Output widget" not in texts:
        fail(f"the Output widget did not capture its print: {texts!r}")
    if not any("image/png" in (o.get("data") or {}) for o in outs
               if o.get("output_type") == "display_data"):
        fail("the Output widget did not capture its plot (image/png)")

    nbformat.validate(nb)
    tmp = DST + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(nb, f, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")
    back = nbformat.read(tmp, as_version=4)
    nbformat.validate(back)
    if back.metadata.get("widgets") != nb.metadata.get("widgets"):
        os.unlink(tmp)
        fail("the written notebook does not read back equal")
    os.replace(tmp, DST)
    print(f"wrote {DST} ({os.path.getsize(DST)} bytes): {len(views)} views, "
          f"{len(state)} saved models")


if __name__ == "__main__":
    main()
