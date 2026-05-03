/**
 * Append-only conversation thread for Claim records.
 *
 * Both OEM (WC_ClaimDecision) and Dealer (WC_DealerServicePortalController)
 * call appendEntry() so a single Claim_Conversation_Log__c field captures
 * the full back-and-forth history. Each entry is one line, machine-parseable
 * by parseEntries().
 *
 * Format (one line per entry, never modified once written):
 *   [ISO_TIMESTAMP|ROLE|AUTHOR_NAME] body text on one or more lines
 * Subsequent lines belonging to the same entry start with two spaces.
 *
 * Example:
 *   [2026-05-01T10:30:00Z|OEM|Vikram Singh] Need clearer photos of the damage.
 *     Specifically the underside near the battery pack.
 *   [2026-05-01T10:45:00Z|DEALER|Santosh Mumbai Premium] Photos attached.
 *
 * Roles:
 *   OEM     — approver / underwriter side
 *   DEALER  — dealer service portal user
 *   SYSTEM  — automated entries (status flips, etc.)
 */
public with sharing class ClaimConversationService {

    // Role identifiers — String constants avoid conflicts with reserved
    // Apex namespaces (SYSTEM, SYS) that an enum value would trigger.
    public static final String ROLE_OEM    = 'OEM';
    public static final String ROLE_DEALER = 'DEALER';
    public static final String ROLE_SYSTEM = 'SYSTEM';

    /** Append a new line to the claim's conversation log. Returns the new full
     *  log value so callers can set it on a Claim record without re-querying.
     *  Thread-safe enough for our scale: trigger-level concurrency is unlikely
     *  for the same claim record from two surfaces simultaneously, and last-
     *  writer-wins is acceptable for a chat log (lost messages are obvious to
     *  the user and they retry).
     */
    public static String appendEntry(String existingLog, String role, String authorName, String body) {
        if (String.isBlank(body)) return existingLog;
        String safeBody = body.replace('\r', '').trim();
        // Indent continuation lines with two spaces so parser can detect them
        safeBody = safeBody.replace('\n', '\n  ');
        String ts   = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String name = String.isBlank(authorName) ? UserInfo.getName() : authorName;
        String roleStr = String.isBlank(role) ? ROLE_SYSTEM : role;
        String line = '[' + ts + '|' + roleStr + '|' + name + '] ' + safeBody;
        if (String.isBlank(existingLog)) return line;
        return existingLog + '\n' + line;
    }

    /** Parse a stored log into a list of entries for UI rendering. */
    public static List<Entry> parseEntries(String log) {
        List<Entry> result = new List<Entry>();
        if (String.isBlank(log)) return result;
        String[] lines = log.split('\n');
        Entry current = null;
        for (String line : lines) {
            // New entry header: starts with [ISO|ROLE|NAME]
            if (line != null && line.length() > 22 && line.startsWith('[')) {
                Integer endIdx = line.indexOf(']');
                if (endIdx > 0) {
                    String header = line.substring(1, endIdx);
                    String[] parts = header.split('\\|');
                    if (parts.size() == 3) {
                        if (current != null) result.add(current);
                        current = new Entry();
                        current.timestamp  = parts[0];
                        current.role       = parts[1];
                        current.author     = parts[2];
                        current.body       = (line.length() > endIdx + 2) ? line.substring(endIdx + 2) : '';
                        continue;
                    }
                }
            }
            // Continuation line (indented with two spaces)
            if (current != null) {
                String more = line.startsWith('  ') ? line.substring(2) : line;
                current.body += '\n' + more;
            }
        }
        if (current != null) result.add(current);
        return result;
    }

    public class Entry {
        @AuraEnabled public String timestamp;
        @AuraEnabled public String role;     // OEM | DEALER | SYSTEM
        @AuraEnabled public String author;
        @AuraEnabled public String body;
    }
}