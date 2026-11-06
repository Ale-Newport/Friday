"""The sidecar's own user-facing strings exist in English and Spanish and never name Jarvis."""

import pytest

from jarvis import texts


def test_every_text_has_both_languages_and_says_friday():
    for key, entry in texts._TEXTS.items():
        assert set(entry) == {"en", "es"}, key
        assert entry["en"].strip() and entry["es"].strip(), key
        assert "Jarvis" not in entry["en"] and "Jarvis" not in entry["es"], key
        assert entry["en"] != entry["es"] or "{" in entry["en"], key  # a translation, not a copy (pure templates aside)


@pytest.mark.parametrize(("value", "expected"), [("es", "es"), ("es-ES", "es"), ("Spanish", "es"), ("ES_MX", "es"), ("en", "en"),
                                                 ("en-GB", "en"), (None, "en"), ("", "en"), ("fr", "en")])
def test_language_codes_are_normalised(value, expected):
    assert texts.normalize_language(value) == expected


def test_texts_are_formatted_in_the_requested_language():
    assert texts.t("en", "confirm_upload", name="cv.pdf", host="jobs.test") == 'Upload "cv.pdf" to jobs.test?'
    assert texts.t("es", "confirm_upload", name="cv.pdf", host="jobs.test") == "¿Subir «cv.pdf» a jobs.test?"
    assert texts.t("es", "budget_minutes", minutes=10.0) == "Se agotó el tiempo máximo de 10 minutos."
    assert texts.t("de", "done") == "Done."  # unknown languages fall back to English
    assert texts.language_name("es") == "Spanish" and texts.language_name(None) == "English"
