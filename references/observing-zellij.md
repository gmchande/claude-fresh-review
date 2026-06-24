# Observing Zellij Reviews

Use this only when the visible Claude session is ambiguous.

- A done marker with `0` means read the handoff.
- A non-zero marker usually means the run failed or was interrupted; read the
  handoff if it exists before discarding the review.
- If the marker is absent, the review is still pending; keep polling until about
  15 minutes have passed.
- If pane/session inspection says the session is gone or exited, check the marker
  and handoff paths directly before diagnosing or rerunning.
- If the session is repeatedly gone/exited and the marker is still absent after a
  brief recheck, treat the run as failed or ambiguous.
- Prefer viewport-only `dump-screen`; use a full transcript only for diagnostics.
