public without sharing class WC_ClaimNameGenerator {

    @TestVisible
    private static Integer cachedMax = -1;

    private static final String PREFIX = 'WC-';
    private static final Integer PAD = 6;

    public static String next() {
        if (cachedMax < 0) {
            cachedMax = currentMax();
        }
        cachedMax++;
        return format(cachedMax);
    }

    public static List<String> nextBatch(Integer count) {
        if (count == null || count <= 0) return new List<String>();
        List<String> names = new List<String>();
        for (Integer i = 0; i < count; i++) {
            names.add(next());
        }
        return names;
    }

    public static void reset() {
        cachedMax = -1;
    }

    private static Integer currentMax() {
        // Underscore in LIKE matches exactly one char, so 'WC-______' = WC- + 6 chars
        AggregateResult ar = [
            SELECT MAX(Name) maxName
            FROM Claim
            WHERE Name LIKE 'WC-______'
        ];
        String name = (String) ar.get('maxName');
        if (String.isBlank(name)) return 0;
        String tail = name.substring(PREFIX.length());
        return tail.isNumeric() ? Integer.valueOf(tail) : 0;
    }

    private static String format(Integer n) {
        return PREFIX + String.valueOf(n).leftPad(PAD, '0');
    }
}