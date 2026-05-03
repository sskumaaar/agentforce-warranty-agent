public without sharing class WC_BotStatus {

    private static final String AGENT_NAME = 'Electra_Dealer_Assistant';

    @AuraEnabled(cacheable=false)
    public static String get() {
        try {
            // [v22.6] WITH SYSTEM_MODE bypasses CC+ profile object-permission
            // gaps on BotVersion. `without sharing` alone covers sharing rules
            // but not object perms — many portal users can't query BotVersion
            // under USER_MODE, which silently returned 'Unknown' before.
            //
            // Take the LATEST version; if it's not Active, the agent runtime
            // will refuse askAgentforce() calls so we surface as offline.
            List<BotVersion> bvs = [
                SELECT Status
                FROM   BotVersion
                WHERE  BotDefinition.DeveloperName = :AGENT_NAME
                WITH   SYSTEM_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (bvs.isEmpty()) return 'Unknown';
            return String.valueOf(bvs[0].Status);
        } catch (Exception e) {
            return 'Unknown';
        }
    }
}