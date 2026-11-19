from pathlib import Path
import pytest
from scripts.prepare_tome_web_assets import safe_name, output_path


def test_steam_relative_png_paths_stay_within_asset_root(tmp_path):
    name = "data/gfx/shockbolt/terrain/marble_floor.png"
    assert safe_name(name) == name
    assert output_path(name, tmp_path) == (tmp_path / name).resolve()


@pytest.mark.parametrize("name", [
    "data/gfx/C:/outside.png", "data/gfx/C:outside.png",
    "data/gfx/../outside.png", "data/gfx/dir\\outside.png",
    "/data/gfx/outside.png", "data/gfx/icon.jpg",
])
def test_rejects_unsafe_paths(name, tmp_path):
    with pytest.raises(ValueError):
        output_path(name, tmp_path)
