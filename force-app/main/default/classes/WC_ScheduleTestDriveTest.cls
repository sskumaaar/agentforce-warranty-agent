@isTest
private class WC_ScheduleTestDriveTest {

    @isTest
    static void testScheduleTestDrive_AllFields() {
        WC_ScheduleTestDrive.Input inp = new WC_ScheduleTestDrive.Input();
        inp.customerName = 'Arun Patel';
        inp.preferredDate = Date.today().addDays(3);
        inp.vehicleModel = 'Electra Thunder 2024';
        inp.contactPhone = '9876543210';
        inp.contactEmail = 'arun@example.com';
        inp.notes = 'Loaner while Electra Bolt is in warranty repair';

        Test.startTest();
        List<WC_ScheduleTestDrive.Output> results = WC_ScheduleTestDrive.execute(
            new List<WC_ScheduleTestDrive.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].success);
        Assert.isNotNull(results[0].testDriveId);
        Assert.isTrue(results[0].message.contains('Test drive scheduled'));
        Assert.isTrue(results[0].message.contains('Arun Patel'));

        Test_Drive__c created = [
            SELECT Model_Interested__c, Status__c, Mobile_Number__c, Test_Drive_Date_Time__c
            FROM Test_Drive__c WHERE Id = :results[0].testDriveId
        ];
        Assert.areEqual('Electra Thunder 2024', created.Model_Interested__c);
        Assert.areEqual('Scheduled', created.Status__c);
        Assert.isNotNull(created.Test_Drive_Date_Time__c);
    }

    @isTest
    static void testScheduleTestDrive_MinimalFields() {
        WC_ScheduleTestDrive.Input inp = new WC_ScheduleTestDrive.Input();
        inp.customerName = 'Priya Singh';
        inp.preferredDate = Date.today().addDays(7);

        Test.startTest();
        List<WC_ScheduleTestDrive.Output> results = WC_ScheduleTestDrive.execute(
            new List<WC_ScheduleTestDrive.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].success);

        Test_Drive__c created = [
            SELECT Model_Interested__c FROM Test_Drive__c WHERE Id = :results[0].testDriveId
        ];
        Assert.areEqual('Any Electra Model', created.Model_Interested__c);
    }

    @isTest
    static void testScheduleTestDrive_MissingCustomerName() {
        WC_ScheduleTestDrive.Input inp = new WC_ScheduleTestDrive.Input();
        inp.preferredDate = Date.today().addDays(5);

        Test.startTest();
        List<WC_ScheduleTestDrive.Output> results = WC_ScheduleTestDrive.execute(
            new List<WC_ScheduleTestDrive.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].success);
        Assert.isTrue(results[0].message.contains('Customer name'));
    }

    @isTest
    static void testScheduleTestDrive_MissingDate() {
        WC_ScheduleTestDrive.Input inp = new WC_ScheduleTestDrive.Input();
        inp.customerName = 'Vikram Desai';

        Test.startTest();
        List<WC_ScheduleTestDrive.Output> results = WC_ScheduleTestDrive.execute(
            new List<WC_ScheduleTestDrive.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].success);
        Assert.isTrue(results[0].message.contains('Preferred date'));
    }

    @isTest
    static void testBulk_200() {
        List<WC_ScheduleTestDrive.Input> inputs = new List<WC_ScheduleTestDrive.Input>();
        for (Integer i = 0; i < 200; i++) {
            WC_ScheduleTestDrive.Input inp = new WC_ScheduleTestDrive.Input();
            inp.customerName = 'Bulk Customer ' + i;
            inp.preferredDate = Date.today().addDays(i + 1);
            inp.vehicleModel = 'Electra Bolt 2025';
            inputs.add(inp);
        }

        Test.startTest();
        List<WC_ScheduleTestDrive.Output> results = WC_ScheduleTestDrive.execute(inputs);
        Test.stopTest();

        Assert.areEqual(200, results.size());
        Integer successCount = 0;
        for (WC_ScheduleTestDrive.Output out : results) {
            if (out.success) { successCount++; }
        }
        Assert.isTrue(successCount > 0, 'At least some test drives should be created');
    }
}