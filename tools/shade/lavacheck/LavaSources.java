// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.file.*;import mcopt.metal.shade.*;
public class LavaSources { public static void main(String[]args)throws Exception{if(ShadeLook.SIZE!=1120||ShadeLook.LAVA_STILL!=1088||ShadeLook.LAVA_FLOW!=1104)throw new AssertionError("layout");Files.writeString(Path.of(args[0]),ShadeMsl.post()+ShadeMsl.resource("lava.metal"));} }
