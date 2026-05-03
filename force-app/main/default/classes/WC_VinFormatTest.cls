@IsTest
private class WC_VinFormatTest {

    @IsTest
    static void canonicalVinAccepted() {
        System.assertEquals(true, WC_VinFormat.isValid('1ELEC2025BOLT0001'),
            '17-char Electra VIN must validate');
    }

    @IsTest
    static void lowercaseVinAcceptedViaUpperFold() {
        System.assertEquals(true, WC_VinFormat.isValid('1elec2025bolt0001'),
            'Validator must upper-fold input before regex check');
    }

    @IsTest
    static void blankRejected() {
        System.assertEquals(false, WC_VinFormat.isValid(null));
        System.assertEquals(false, WC_VinFormat.isValid(''));
        System.assertEquals(false, WC_VinFormat.isValid('   '));
    }

    @IsTest
    static void wrongPrefixRejected() {
        System.assertEquals(false, WC_VinFormat.isValid('1HIST2025BOLT0001'),
            'VINs without 1ELEC prefix must reject');
        System.assertEquals(false, WC_VinFormat.isValid('TESLA12345BOLT001'),
            'Even with 17 chars, wrong prefix rejects');
    }

    @IsTest
    static void wrongLengthRejected() {
        System.assertEquals(false, WC_VinFormat.isValid('1ELEC2025BOLT001'),  // 16 chars
            '16-char VIN must reject');
        System.assertEquals(false, WC_VinFormat.isValid('1ELEC2025BOLT00001'), // 18 chars
            '18-char VIN must reject');
        System.assertEquals(false, WC_VinFormat.isValid('1ELEC'),               // 5 chars
            'Too-short VIN must reject');
    }

    @IsTest
    static void requireValidThrowsForInvalid() {
        Boolean threw = false;
        try {
            WC_VinFormat.requireValid('NOT-A-VIN');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'requireValid must throw for non-canonical input');
    }

    @IsTest
    static void requireValidPassesForCanonical() {
        WC_VinFormat.requireValid('1ELEC2025BOLT0001');
        // No exception = pass
    }

    @IsTest
    static void specialCharsRejected() {
        System.assertEquals(false, WC_VinFormat.isValid('1ELEC2025BOLT-001'),
            'Hyphens not allowed in canonical VIN');
        System.assertEquals(false, WC_VinFormat.isValid('1ELEC2025BOLT 001'),
            'Spaces not allowed in canonical VIN');
    }
}