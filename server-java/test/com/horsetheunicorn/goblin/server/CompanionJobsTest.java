package com.horsetheunicorn.goblin.server;

/** Checks the installed native signatures without opening a game or mutating a world. */
public final class CompanionJobsTest {
    public static void main(String[] args) throws Exception {
        if (CompanionJobs.craft(null, null)) throw new AssertionError("null craft allowed");
        if (CompanionJobs.repair(null, null, null, null)) throw new AssertionError("null repair allowed");
        // Initializing this adapter resolves BOTH version-specific phases before
        // any craft may consume ingredients. A signature drift fails this test.
        Class<?> methods=Class.forName("com.horsetheunicorn.goblin.server.CompanionJobs$CraftMethods");
        for (String name : new String[]{"CONSUME","OUTPUT"}) {
            var field=methods.getDeclaredField(name);
            field.setAccessible(true);
            var method=(java.lang.reflect.Method)field.get(null);
            if (method.getReturnType()!=boolean.class) throw new AssertionError("native return type changed");
        }
        System.out.println("CompanionJobsTest: 4 native boundary checks passed");
    }
}
