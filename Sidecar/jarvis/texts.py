"""The few sidecar strings a person reads or hears, in English and Spanish.

Friday (the host app) localises everything it shows itself from structured event data; these texts cover what the
sidecar writes on its own: task summaries, budget and recovery messages and the fallback copy of confirmation requests.
"""

from __future__ import annotations

from typing import Any

LANGUAGES = ("en", "es")

_TEXTS: dict[str, dict[str, str]] = {
    "cancelled": {"en": "Task cancelled.", "es": "Tarea cancelada."},
    "could_not_complete": {"en": "I couldn't complete that: {reason}.", "es": "No he podido completarlo: {reason}."},
    "nothing_worked": {"en": "nothing worked", "es": "nada funcionó"},
    "done": {"en": "Done.", "es": "Hecho."},
    "could_not_finish": {"en": "I could not finish this.", "es": "No he podido terminar esto."},
    "done_page_open": {"en": "Done — **{title}** is open: <{url}>", "es": "Hecho — **{title}** está abierta: <{url}>"},
    "stopped_on": {"en": "Stopped on **{title}**: <{url}>", "es": "Me he detenido en **{title}**: <{url}>"},
    "could_not_verify": {"en": "**Could not verify:**", "es": "**No se pudo verificar:**"},
    "partially_completed": {"en": "Partially completed: {reason}", "es": "Completado parcialmente: {reason}"},
    "summary_failed": {"en": "The written summary could not be generated: {reason}", "es": "No se pudo generar el resumen escrito: {reason}"},
    "budget_minutes": {"en": "The {minutes:g}-minute time budget ran out.", "es": "Se agotó el tiempo máximo de {minutes:g} minutos."},
    "budget_actions": {"en": "The {steps}-action budget ran out.", "es": "Se agotó el máximo de {steps} acciones."},
    "too_many_replans": {"en": "Stopped after too many replans without finishing.", "es": "Me he detenido tras replanificar demasiadas veces sin terminar."},
    "same_step_failing": {"en": "The same kind of step kept failing.", "es": "El mismo tipo de paso siguió fallando."},
    "repeating_steps": {"en": "The plan started repeating steps that already ran.", "es": "El plan empezó a repetir pasos que ya se habían ejecutado."},
    "final_page_unconfirmed": {"en": "The final page could not be confirmed as what you asked for.", "es": "No se pudo confirmar que la página final sea lo que pediste."},
    "declined": {"en": 'You declined "{label}".', "es": "Rechazaste «{label}»."},
    "that_action": {"en": "that action", "es": "esa acción"},
    "declined_download": {"en": "The user declined the download.", "es": "El usuario rechazó la descarga."},
    "declined_upload": {"en": "The user declined the upload.", "es": "El usuario rechazó la subida."},
    "reconnecting": {"en": "Chrome disconnected — reconnecting…", "es": "Chrome se desconectó — reconectando…"},
    "reopening_tab": {"en": "The tab was closed — opening it again…", "es": "La pestaña se cerró — abriéndola de nuevo…"},
    "resumed_after_reconnect": {"en": "Resumed after Chrome reconnected.", "es": "Reanudado tras reconectar Chrome."},
    "reconnect_failed": {"en": "Chrome disconnected and could not be reconnected after {attempts} attempts.",
                         "es": "Chrome se desconectó y no se pudo reconectar tras {attempts} intentos."},
    # Fallback confirmation copy (Friday builds its own from the structured data; the web UI shows these).
    "confirm_payment": {"en": 'Friday is about to click "{label}" on {host}, which may spend money or submit a payment.',
                        "es": "Friday va a pulsar «{label}» en {host}, lo que puede gastar dinero o enviar un pago."},
    "confirm_purchase": {"en": 'Friday is about to click "{label}" on {host}, which may make a booking or purchase.',
                         "es": "Friday va a pulsar «{label}» en {host}, lo que puede hacer una reserva o una compra."},
    "confirm_destructive": {"en": 'Friday is about to click "{label}" on {host}, which may delete or cancel something.',
                            "es": "Friday va a pulsar «{label}» en {host}, lo que puede borrar o cancelar algo."},
    "confirm_account": {"en": 'Friday is about to click "{label}" on {host}, which may change account settings or permissions.',
                        "es": "Friday va a pulsar «{label}» en {host}, lo que puede cambiar ajustes o permisos de la cuenta."},
    "confirm_send": {"en": 'Friday is about to click "{label}" on {host}, which may send or publish content.',
                     "es": "Friday va a pulsar «{label}» en {host}, lo que puede enviar o publicar contenido."},
    "confirm_other": {"en": 'Friday is about to click "{label}" on {host}.', "es": "Friday va a pulsar «{label}» en {host}."},
    "confirm_download": {"en": "Download {name} to {folder}?", "es": "¿Descargar {name} en {folder}?"},
    "confirm_upload": {"en": 'Upload "{name}" to {host}?', "es": "¿Subir «{name}» a {host}?"},
    "page_detail": {"en": "Page: {title} — {url}", "es": "Página: {title} — {url}"},
    "an_inline_image": {"en": "an inline image", "es": "una imagen incrustada"},
    "this_site": {"en": "this site", "es": "este sitio"},
}


def normalize_language(value: Any) -> str:
    """"es", "es-ES", "Spanish"… → "es"; anything else → "en"."""
    raw = str(value or "").strip().lower()
    return "es" if raw.startswith(("es", "spa")) else "en"


def t(language: str | None, key: str, **values: Any) -> str:
    entry = _TEXTS[key]
    text = entry.get(normalize_language(language), entry["en"])
    return text.format(**values) if values else text


def language_name(language: str | None) -> str:
    return "Spanish" if normalize_language(language) == "es" else "English"


__all__ = ["LANGUAGES", "language_name", "normalize_language", "t"]
