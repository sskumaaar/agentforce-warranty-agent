/**
 * WC_AgentforceProxy
 *
 * Bridge between the LWC chat panel and the deployed Agentforce bot
 * (Electra_Dealer_Assistant). Uses the standard Salesforce invocable action
 * "generateAiAgentResponse" to talk to the agent — no MIAW, no REST callout,
 * no AIApplication registration needed.
 *
 * Agent API name is the BotDefinition.DeveloperName (Setup → Agents).
 */
public with sharing class WC_AgentforceProxy {

    private static final String AGENT_NAME      = 'Electra_Dealer_Assistant';
    private static final String INVOCABLE_NAME  = 'generateAiAgentResponse';

    /**
     * Sends a user message to the deployed Agentforce agent and returns the
     * raw agent response (typically JSON) plus the parsed text reply.
     *
     * @param userMessage  what the dealer typed
     * @param sessionId    optional — pass back the previous response's
     *                     sessionId for multi-turn context
     * @return Map { success, replyText, sessionId, raw, error }
     */
    @AuraEnabled
    public static Map<String, Object> ask(String userMessage, String sessionId) {
        Map<String, Object> out = new Map<String, Object>{
            'success'   => false,
            'replyText' => null,
            'sessionId' => null,
            'raw'       => null,
            'error'     => null
        };
        try {
            if (String.isBlank(userMessage)) {
                out.put('error', 'userMessage is required');
                return out;
            }

            Invocable.Action.Result r = invokeOnce(userMessage, sessionId);

            // RETRY PATH — Agentforce ends sessions when the agent's bot dialog
            // hits an end-state (e.g., a Welcome topic that completes). The
            // next call with the dead sessionId returns HTTP 410 with
            // SessionAlreadyEndedException. Recover transparently by retrying
            // ONCE with sessionId=null so the runtime mints a fresh session.
            if (r != null && !r.isSuccess()) {
                String errStr = String.valueOf(r.getErrors());
                Boolean ended = errStr != null
                    && (errStr.contains('SessionAlreadyEnded')
                        || errStr.contains('already ended')
                        || errStr.contains('"status":410')
                        || errStr.contains('response code 410'));
                if (ended && String.isNotBlank(sessionId)) {
                    System.debug(LoggingLevel.INFO, 'WC_AgentforceProxy retrying with fresh session');
                    r = invokeOnce(userMessage, null);
                }
            }

            if (r == null) {
                out.put('error', 'Agent returned no results');
                return out;
            }
            if (!r.isSuccess()) {
                out.put('error', 'Agent action failed: ' + String.valueOf(r.getErrors()));
                return out;
            }

            Map<String, Object> outParams = r.getOutputParameters();
            out.put('raw', String.valueOf(outParams));

            // Delegate to a TestVisible parser so the mostly-data-shaping
            // logic can be unit-tested without a live invocable callout.
            Map<String, Object> parsed = parseAgentOutParams(outParams);
            out.put('success',   parsed.get('replyText') != null);
            out.put('replyText', parsed.get('replyText'));
            out.put('sessionId', parsed.get('sessionId'));
            return out;

        } catch (Exception e) {
            out.put('error', e.getMessage() + ' (' + e.getTypeName() + ')');
            return out;
        }
    }

    /**
     * Parse the raw output params returned by the Agentforce invocable into
     * { replyText, sessionId }. Pure data-shape logic — no callouts — so the
     * unit test suite can exercise every branch with mock Maps. The Agent
     * invocable returns one of three flavours:
     *   - { agentResponse: "...", sessionId: "..." }
     *   - { value: "raw text" }
     *   - { value: '{"value":"unwrapped","text":"..."}' }   (double-wrapped JSON)
     */
    @TestVisible
    private static Map<String, Object> parseAgentOutParams(Map<String, Object> outParams) {
        String replyText = null;
        String newSessionId = null;
        if (outParams != null) {
            if (outParams.containsKey('agentResponse')) {
                Object ar = outParams.get('agentResponse');
                replyText = ar == null ? null : String.valueOf(ar);
            }
            if (outParams.containsKey('sessionId') && outParams.get('sessionId') != null) {
                newSessionId = String.valueOf(outParams.get('sessionId'));
            }
            // Some flavours return a JSON value field
            if (replyText == null && outParams.containsKey('value')) {
                Object v = outParams.get('value');
                replyText = v == null ? null : String.valueOf(v);
            }
        }
        // If reply is JSON, try to extract a "value" / "text" field
        if (String.isNotBlank(replyText) && replyText.startsWith('{')) {
            try {
                Map<String, Object> j = (Map<String, Object>) JSON.deserializeUntyped(replyText);
                if (j.containsKey('value'))     replyText = String.valueOf(j.get('value'));
                else if (j.containsKey('text')) replyText = String.valueOf(j.get('text'));
            } catch (Exception je) { /* non-json — keep as-is */ }
        }
        return new Map<String, Object>{ 'replyText' => replyText, 'sessionId' => newSessionId };
    }

    /**
     * One pass at the agent invocable — pulled out so ask() can retry once
     * with a fresh session if the original sessionId has been ended.
     */
    private static Invocable.Action.Result invokeOnce(String userMessage, String sessionId) {
        Invocable.Action action = Invocable.Action.createCustomAction(
            INVOCABLE_NAME, AGENT_NAME
        );
        action.setInvocationParameter('userMessage', userMessage);
        if (String.isNotBlank(sessionId)) {
            action.setInvocationParameter('sessionId', sessionId);
        }
        List<Invocable.Action.Result> results = action.invoke();
        return (results == null || results.isEmpty()) ? null : results[0];
    }

    /**
     * Quick health probe used by the LWC on chat open. Returns true if the
     * proxy is callable + the agent invocable exists. Doesn't actually invoke.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean isAvailable() {
        try {
            Invocable.Action action = Invocable.Action.createCustomAction(
                INVOCABLE_NAME,
                AGENT_NAME
            );
            return action != null;
        } catch (Exception e) {
            return false;
        }
    }
}