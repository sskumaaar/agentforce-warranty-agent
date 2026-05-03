@IsTest
private class WC_FollowUpQuestionsTest {
    @IsTest
    static void testSuggest() {
        Account d = new Account(Name = 'Bay Area Electra Motors');
        insert d;
        Claim cl = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = d.Id,
            Status = 'Under Review',
            Summary = 'Test',
            EstimatedAmount = 100,
            InitiationDate = Date.today(),
            Channel__c = 'Portal',
            DealerCode__c = 'DLR-001'
        );
        insert cl;
        WC_FollowUpQuestions.Inp i = new WC_FollowUpQuestions.Inp();
        i.claimId = cl.Id;
        Test.startTest();
        List<WC_FollowUpQuestions.Out> r = WC_FollowUpQuestions.suggest(new List<WC_FollowUpQuestions.Inp>{ i });
        Test.stopTest();
        System.assert(!r.isEmpty());
        System.assert(String.isNotBlank(r[0].questions));
    }
}