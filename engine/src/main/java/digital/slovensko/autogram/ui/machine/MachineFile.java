package digital.slovensko.autogram.ui.machine;

import digital.slovensko.autogram.ui.machine.v2.VisibleSignatureAppearance;

import java.util.List;

/// One machine protocol file. `attachments` are further documents signed together with the
/// source as separate data objects of one ASiC-E (ZaKo: the PDF/A and its clause XDC).
/// `appendClause`, when present, is appended to the PDF source before a PAdES signature
/// (ZaKo's one-PDF output); never together with attachments.
public record MachineFile(String id, String source, String target, VisibleSignatureAppearance.Snapshot visibleAppearance,
        List<String> attachments, ClauseAppend appendClause) {
    public MachineFile {
        attachments = attachments == null ? List.of() : List.copyOf(attachments);
    }

    public MachineFile(String id, String source, String target, VisibleSignatureAppearance.Snapshot visibleAppearance,
            List<String> attachments) {
        this(id, source, target, visibleAppearance, attachments, null);
    }

    public MachineFile(String id, String source, String target, VisibleSignatureAppearance.Snapshot visibleAppearance) {
        this(id, source, target, visibleAppearance, List.of(), null);
    }

    public MachineFile(String id, String source, String target) {
        this(id, source, target, null, List.of(), null);
    }
}
