@isTest
private class WC_CreateLeadTest {

    @isTest
    static void testCreateLead_AllFields() {
        WC_CreateLead.Input inp = new WC_CreateLead.Input();
        inp.vinNumber = '1ELEC2025UNKN0001';
        inp.dealerName = 'Bay Area Electra Motors';
        inp.contactName = 'Rajesh Sharma';
        inp.contactEmail = 'rajesh@bayareaelectra.com';
        inp.contactPhone = '+919876543210';
        inp.vehicleDetails = '2024 Electra Thunder, Blue';
        inp.inquiryNotes = 'Customer claims vehicle was purchased overseas';

        Test.startTest();
        List<WC_CreateLead.Output> results = WC_CreateLead.execute(
            new List<WC_CreateLead.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].success);
        Assert.isNotNull(results[0].leadId);
        Assert.isTrue(results[0].message.contains('Lead created'));

        Lead created = [SELECT FirstName, LastName, Company, Email, Phone, LeadSource, Description
                        FROM Lead WHERE Id = :results[0].leadId];
        Assert.areEqual('Rajesh', created.FirstName);
        Assert.areEqual('Sharma', created.LastName);
        Assert.areEqual('Bay Area Electra Motors', created.Company);
        Assert.areEqual('rajesh@bayareaelectra.com', created.Email);
        Assert.areEqual('Agentforce - Warranty Inquiry', created.LeadSource);
        Assert.isTrue(created.Description.contains('1ELEC2025UNKN0001'));
    }

    @isTest
    static void testCreateLead_MinimalFields() {
        WC_CreateLead.Input inp = new WC_CreateLead.Input();
        inp.vinNumber = '1ELEC2025UNKN0002';
        inp.dealerName = 'Pune Electra Service Center';

        Test.startTest();
        List<WC_CreateLead.Output> results = WC_CreateLead.execute(
            new List<WC_CreateLead.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].success);

        Lead created = [SELECT LastName, Company FROM Lead WHERE Id = :results[0].leadId];
        Assert.areEqual('Pune Electra Service Center', created.LastName);
        Assert.areEqual('Pune Electra Service Center', created.Company);
    }

    @isTest
    static void testCreateLead_MissingVIN() {
        WC_CreateLead.Input inp = new WC_CreateLead.Input();
        inp.dealerName = 'Test Dealer';

        Test.startTest();
        List<WC_CreateLead.Output> results = WC_CreateLead.execute(
            new List<WC_CreateLead.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].success);
        Assert.isTrue(results[0].message.contains('VIN'));
    }

    @isTest
    static void testCreateLead_MissingDealer() {
        WC_CreateLead.Input inp = new WC_CreateLead.Input();
        inp.vinNumber = '1ELEC2025UNKN0003';

        Test.startTest();
        List<WC_CreateLead.Output> results = WC_CreateLead.execute(
            new List<WC_CreateLead.Input>{ inp }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].success);
        Assert.isTrue(results[0].message.contains('Dealer'));
    }

    @isTest
    static void testCreateLead_VerifyDescription() {
        WC_CreateLead.Input inp = new WC_CreateLead.Input();
        inp.vinNumber = '1ELEC2025UNKN0004';
        inp.dealerName = 'Chennai Electra Hub';
        inp.vehicleDetails = 'Electra Luxe 2025';
        inp.inquiryNotes = 'Parallel import from Singapore';

        Test.startTest();
        List<WC_CreateLead.Output> results = WC_CreateLead.execute(
            new List<WC_CreateLead.Input>{ inp }
        );
        Test.stopTest();

        Lead created = [SELECT Description FROM Lead WHERE Id = :results[0].leadId];
        Assert.isTrue(created.Description.contains('1ELEC2025UNKN0004'));
        Assert.isTrue(created.Description.contains('Electra Luxe 2025'));
        Assert.isTrue(created.Description.contains('Parallel import'));
    }

    @isTest
    static void testBulk_200Leads() {
        List<WC_CreateLead.Input> inputs = new List<WC_CreateLead.Input>();
        for (Integer i = 0; i < 200; i++) {
            WC_CreateLead.Input inp = new WC_CreateLead.Input();
            // [v22.1] Canonical 17-char VIN: 1ELEC2025BLK (12) + 5-digit seq.
            inp.vinNumber = '1ELEC2025BLK' + String.valueOf(i).leftPad(5, '0');
            inp.dealerName = 'Electra Dealer ' + i;
            inputs.add(inp);
        }

        Test.startTest();
        List<WC_CreateLead.Output> results = WC_CreateLead.execute(inputs);
        Test.stopTest();

        Assert.areEqual(200, results.size());
        Integer successCount = 0;
        for (WC_CreateLead.Output out : results) {
            if (out.success) { successCount++; }
        }
        Assert.isTrue(successCount > 0, 'At least some leads should be created');
    }
}