@IsTest
private class WC_BotStatusTest {

    @IsTest
    static void getReturnsStringNeverThrows() {
        Test.startTest();
        String s = WC_BotStatus.get();
        Test.stopTest();
        System.assertNotEquals(null, s, 'getBotStatus must return a non-null status string');
        System.assert(
            s == 'Active' || s == 'Inactive' || s == 'Unknown' || s.length() > 0,
            'Status should be one of the known values or a defined string, got: ' + s
        );
    }
}