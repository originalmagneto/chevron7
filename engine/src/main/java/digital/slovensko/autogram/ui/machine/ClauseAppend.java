package digital.slovensko.autogram.ui.machine;

/// The osvedčovacia doložka a PAdES request appends to its PDF/A source before signing it:
/// the rendered clause `pages` (a PDF) and the clause XDC embedded as an associated file under
/// `attachmentName` with `attachmentMimeType`. Paths are absolute, as every machine file path.
public record ClauseAppend(String pages, String attachment, String attachmentName, String attachmentMimeType) {
}
