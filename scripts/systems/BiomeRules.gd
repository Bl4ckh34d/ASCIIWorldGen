# File: res://scripts/systems/BiomeRules.gd
extends RefCounted

## Central biome rules. Pure helper mapping (t_c, moisture, elevation, land/ocean)
## to a Biome ID. This mirrors the high-level rules in the refactor doc and
## current behavior. Not yet wired; classifier will call this in Phase 2/3.

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")

func classify_cell(t_c: float, m: float, elev_norm: float, is_land: bool) -> int:
    if not is_land:
        return BiomeClassifier.Biome.ICE_SHEET if t_c <= -10.0 else BiomeClassifier.Biome.OCEAN

    # Elevation-first bands (collapse foothills into hills)
    if elev_norm > 0.80:
        return BiomeClassifier.Biome.ALPINE
    if elev_norm > 0.60:
        return BiomeClassifier.Biome.MOUNTAINS
    if elev_norm > 0.30:
        # Forest overrides hills: if any forest condition matches, prefer that over hills
        if t_c <= 8.0 and m >= 0.50:
            return BiomeClassifier.Biome.BOREAL_FOREST
        if t_c <= 18.0:
            if m >= 0.60:
                return BiomeClassifier.Biome.TEMPERATE_FOREST
            if m >= 0.45:
                return BiomeClassifier.Biome.BOREAL_FOREST
        if t_c <= 30.0:
            if m >= 0.55:
                return BiomeClassifier.Biome.RAINFOREST
        return BiomeClassifier.Biome.HILLS

    # Temperature/moisture bands
    if t_c <= -10.0:
        return BiomeClassifier.Biome.DESERT_ICE
    if t_c <= 2.0:
        return BiomeClassifier.Biome.TUNDRA if m >= 0.30 else BiomeClassifier.Biome.WASTELAND
    if t_c <= 8.0:
        return BiomeClassifier.Biome.BOREAL_FOREST if m >= 0.50 else BiomeClassifier.Biome.STEPPE
    if t_c <= 18.0:
        if m >= 0.60:
            return BiomeClassifier.Biome.TEMPERATE_FOREST
        if m >= 0.45:
            return BiomeClassifier.Biome.BOREAL_FOREST
        if m >= 0.25:
            return BiomeClassifier.Biome.GRASSLAND
        if m >= 0.20:
            return BiomeClassifier.Biome.STEPPE
        return BiomeClassifier.Biome.WASTELAND
    if t_c <= 30.0:
        if m >= 0.55:
            return BiomeClassifier.Biome.RAINFOREST
        if m >= 0.40:
            return BiomeClassifier.Biome.SAVANNA
        if m >= 0.30:
            return BiomeClassifier.Biome.GRASSLAND
        return BiomeClassifier.Biome.WASTELAND

    # t_c > 30 °C
    if m < 0.40:
        # Desert split (sand vs rock) left to noise; pick rock here to be neutral.
        return BiomeClassifier.Biome.WASTELAND
    # Otherwise apply relief/forest hot overrides
    return BiomeClassifier.Biome.STEPPE


