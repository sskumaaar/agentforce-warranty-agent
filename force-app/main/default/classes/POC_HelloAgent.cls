public with sharing class POC_HelloAgent {

    public class Input {
        @InvocableVariable(label='Name' description='Name of the person to greet. If user did not provide one, pass "World".' required=true)
        public String name;
    }

    public class Output {
        @InvocableVariable(label='Greeting' description='The greeting text returned to the user.')
        public String greeting;

        @InvocableVariable(label='Timestamp' description='When the greeting was generated.')
        public String timestamp;
    }

    @InvocableMethod(
        label='POC Hello Agent'
        description='Returns a friendly greeting. Trigger utterances: "say hello", "say hi to <name>", "greet me", "hello agent". Always pass the name parameter.'
    )
    public static List<Output> hello(List<Input> inputs) {
        List<Output> results = new List<Output>();
        for (Input inp : inputs) {
            Output o = new Output();
            String n = String.isBlank(inp.name) ? 'World' : inp.name;
            o.greeting = 'Hello, ' + n + '! This is the POC Agent confirming a custom Apex action just fired.';
            o.timestamp = String.valueOf(Datetime.now());
            results.add(o);
        }
        return results;
    }
}