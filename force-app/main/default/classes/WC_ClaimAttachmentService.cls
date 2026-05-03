/**
 * Pure file-attach service. Validates MIME + magic bytes, then creates
 * ContentVersion + ContentDocumentLink against the supplied Claim.
 *
 * Access control is the CALLER's responsibility (dealer controller checks
 * dealer-account-owns-claim; OEM controller relies on the approver permset).
 * This class is intentionally unaware of who's attaching — it only does the
 * file plumbing once a caller has decided the action is allowed.
 *
 * Original implementation lived inline in WC_DealerServicePortalController.attachFilesToClaim;
 * extracted here so the OEM Command Center can attach files too without
 * cross-portal imports.
 */
/**
 * [v23.18] `without sharing` — both callers (dealer controller +
 * OEM approval controller) verify dealer-account-owns-claim or
 * approver-permset BEFORE calling attach(). Inside this service we
 * just write ContentVersion + ContentDocumentLink rows; without
 * sharing is required so any dealer user at the dealership can
 * upload to claims their colleague filed (the v23.14 read-side fix
 * was incomplete — it let dealers SEE cross-user claims but the
 * with-sharing CDL insert still threw "Unable to complete request").
 */
public without sharing class WC_ClaimAttachmentService {

    // Modern phone cameras and screenshot tools save in HEIF / WebP just as often as
    // PNG / JPEG. Reject only what's truly unsafe (executables, archives), not legitimate
    // photo formats. iOS in particular sends HEIC photos with MIME 'image/heif' (the
    // standard) sometimes and 'image/heic' other times — both are accepted.
    public static final Set<String> ALLOWED_MIME = new Set<String>{
        'application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp'
    };
    public static final Integer MAX_FILES_PER_CLAIM = 10;

    public class FileInput {
        @AuraEnabled public String name;
        @AuraEnabled public String mimeType;
        @AuraEnabled public String base64Data;
    }

    /**
     * Attach a list of files to a Claim. Returns a result map:
     *   success      Boolean (true if no errors)
     *   attachedCount Integer (how many files actually saved)
     *   failedCount   Integer
     *   errors        List<String> (per-file failure reasons)
     */
    public static Map<String, Object> attach(Id claimId, List<FileInput> files) {
        Map<String, Object> result = new Map<String, Object>{
            'success' => true,
            'attachedCount' => 0,
            'failedCount' => 0,
            'errors' => new List<String>()
        };
        if (claimId == null || files == null || files.isEmpty()) return result;

        Integer existing = [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :claimId];
        if (existing + files.size() > MAX_FILES_PER_CLAIM) {
            result.put('success', false);
            ((List<String>) result.get('errors')).add(
                'Per-claim attachment limit reached (' + MAX_FILES_PER_CLAIM +
                '). Currently ' + existing + '.');
            result.put('failedCount', files.size());
            return result;
        }

        List<String> errors = (List<String>) result.get('errors');
        List<ContentVersion> versions = new List<ContentVersion>();
        for (FileInput f : files) {
            // [v23.19] Most robust path: detect MIME from the file's actual
            // magic bytes BEFORE accepting the client's claimed MIME.
            // Bytes don't lie even when LWS strips file.name / file.type
            // before it reaches Apex. If the magic-byte sniff identifies a
            // supported type, we use that; otherwise we fall back to the
            // client-claimed MIME, then to filename-extension inference.
            Blob raw;
            try { raw = EncodingUtil.base64Decode(f.base64Data); }
            catch (Exception e) {
                errors.add((String.isBlank(f.name) ? 'attachment' : f.name) + ': base64 decode failed');
                continue;
            }
            String detectedMime = detectMimeFromMagic(raw);
            String safeMime = String.isNotBlank(detectedMime) ? detectedMime
                            : (String.isBlank(f.mimeType) ? mimeFromName(f.name) : f.mimeType);
            String safeName = String.isBlank(f.name)
                ? ('attachment' + (String.isNotBlank(detectedMime) ? extFromMime(detectedMime) : ''))
                : f.name;
            if (!ALLOWED_MIME.contains(safeMime)) {
                errors.add(safeName + ': type not allowed (' + safeMime + ')');
                continue;
            }
            f.name = safeName;
            f.mimeType = safeMime;
            // We've already detected MIME from magic bytes above, so the
            // declared-vs-actual check below is mostly a no-op when sniff
            // succeeded. We keep it for the case where we accepted the
            // client-claimed MIME (sniff returned blank).
            if (!hasValidMagicBytes(raw, f.mimeType)) {
                errors.add(f.name + ': content does not match declared MIME');
                continue;
            }
            ContentVersion cv = new ContentVersion();
            cv.VersionData = raw;
            cv.Title = f.name;
            cv.PathOnClient = f.name;
            cv.Origin = 'H';
            versions.add(cv);
        }

        if (!versions.isEmpty()) {
            insert versions;
            Set<Id> cvIds = new Set<Id>();
            for (ContentVersion cv : versions) cvIds.add(cv.Id);
            Map<Id, Id> cvToDoc = new Map<Id, Id>();
            for (ContentVersion cv : [
                SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :cvIds
            ]) cvToDoc.put(cv.Id, cv.ContentDocumentId);

            List<ContentDocumentLink> links = new List<ContentDocumentLink>();
            for (Id cvId : cvToDoc.keySet()) {
                links.add(new ContentDocumentLink(
                    LinkedEntityId    = claimId,
                    ContentDocumentId = cvToDoc.get(cvId),
                    ShareType         = 'V',
                    Visibility        = 'AllUsers'
                ));
            }
            insert links;
            result.put('attachedCount', links.size());
        }
        result.put('failedCount', errors.size());
        result.put('success', errors.isEmpty());
        return result;
    }

    /**
     * [v23.19] Magic-byte MIME detection. Looks at the FIRST FEW BYTES
     * of the decoded file content to identify its real type. The most
     * reliable signal — file bytes survive LWS / browser quirks that
     * strip File.name and File.type. Returns blank if none of the
     * supported types' signatures match, in which case the caller
     * falls back to the client-claimed MIME or filename extension.
     */
    @TestVisible
    private static String detectMimeFromMagic(Blob raw) {
        if (raw == null || raw.size() < 4) return '';
        String hex = EncodingUtil.convertToHex(raw)
            .substring(0, Math.min(24, raw.size() * 2)).toUpperCase();
        if (hex.startsWith('25504446')) return 'application/pdf';   // %PDF
        if (hex.startsWith('FFD8FF'))   return 'image/jpeg';
        if (hex.startsWith('89504E47')) return 'image/png';         // ‰PNG
        // HEIC + HEIF share the ISO BMFF container — bytes 4-11 are 'ftyp' + brand.
        // Brand at 8-15 (hex 16-23): heic, heix, hevc, mif1, msf1, heim, heis, hevm, hevs (heif family)
        if (hex.length() >= 24 && hex.substring(8, 16) == '66747970') {
            String brand = hex.substring(16, 24);
            if (brand.startsWith('48454943') || brand.startsWith('48454958')   // heic, heix
             || brand.startsWith('48455643')) return 'image/heic';             // hevc
            return 'image/heif';
        }
        // WebP: 'RIFF' + 4 size bytes + 'WEBP' = 52 49 46 46 ?? ?? ?? ?? 57 45 42 50
        if (hex.length() >= 24 && hex.startsWith('52494646')
         && hex.substring(16, 24) == '57454250') return 'image/webp';
        return '';
    }

    /** Default extension to attach to a synthetic filename when client sent
     *  blank name but we sniffed the MIME from bytes. */
    private static String extFromMime(String mime) {
        if (mime == 'application/pdf') return '.pdf';
        if (mime == 'image/jpeg')      return '.jpg';
        if (mime == 'image/png')       return '.png';
        if (mime == 'image/heic')      return '.heic';
        if (mime == 'image/heif')      return '.heif';
        if (mime == 'image/webp')      return '.webp';
        return '';
    }

    /**
     * [v23.16] Best-effort MIME inference from filename extension. Used as
     * a defensive fallback when the client sent null/blank mimeType (some
     * browsers + LWS combos strip File.type before the LWC can read it).
     * Returns 'application/octet-stream' for unknown extensions, which
     * the ALLOWED_MIME check then refuses with a clear error.
     */
    @TestVisible
    private static String mimeFromName(String fileName) {
        if (String.isBlank(fileName) || !fileName.contains('.')) return 'application/octet-stream';
        String ext = fileName.substringAfterLast('.').toLowerCase();
        if (ext == 'pdf')                         return 'application/pdf';
        if (ext == 'jpg' || ext == 'jpeg')        return 'image/jpeg';
        if (ext == 'png')                         return 'image/png';
        if (ext == 'heic')                        return 'image/heic';
        if (ext == 'heif')                        return 'image/heif';
        if (ext == 'webp')                        return 'image/webp';
        return 'application/octet-stream';
    }

    /**
     * Verify the first 4-8 bytes of the decoded blob match the declared MIME type's
     * magic-number signature. Defends against MIME-spoofing where someone uploads
     * an executable claiming to be a PNG.
     */
    @TestVisible
    private static Boolean hasValidMagicBytes(Blob raw, String mime) {
        if (raw == null || raw.size() < 4) return false;
        // Read up to 24 hex chars (12 bytes) — needed for WebP's 'RIFF…WEBP' check.
        String hex = EncodingUtil.convertToHex(raw)
            .substring(0, Math.min(24, raw.size() * 2)).toUpperCase();
        if (mime == 'application/pdf') return hex.startsWith('25504446');                       // %PDF
        if (mime == 'image/jpeg')      return hex.startsWith('FFD8FF');
        if (mime == 'image/png')       return hex.startsWith('89504E47');                       // ‰PNG
        // HEIC + HEIF share the ISO BMFF container — bytes 4-7 are 'ftyp', bytes 8-11 the brand.
        if (mime == 'image/heic' || mime == 'image/heif') {
            return hex.length() >= 16 && hex.substring(8, 16).startsWith('66747970');
        }
        // WebP: 'RIFF' + 4 size bytes + 'WEBP' = 52 49 46 46 ?? ?? ?? ?? 57 45 42 50
        if (mime == 'image/webp') {
            return hex.length() >= 24 && hex.startsWith('52494646') && hex.substring(16, 24) == '57454250';
        }
        return false;
    }
}