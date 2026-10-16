// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.*;
import java.nio.file.*;
import org.lwjgl.*;
import org.lwjgl.system.*;
import static org.lwjgl.util.shaderc.Shaderc.*;
import static org.lwjgl.util.spvc.Spvc.*;
public class Translate {
 public static void main(String[] args) throws Exception {
 String source;
 try(var zip=new java.util.zip.ZipFile(args[0])) {
  source=new String(zip.getInputStream(zip.getEntry("assets/minecraft/shaders/core/rendertype_beacon_beam.fsh")).readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
  source=source.replace("#version 330","#version 450");
  for(String name:new String[]{"fog","dynamictransforms"}) {
   String include=new String(zip.getInputStream(zip.getEntry("assets/minecraft/shaders/include/"+name+".glsl")).readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
   source=source.replace("#include <minecraft:"+name+".glsl>",include);
  }
  // Shading disables improved transparency; these are the two conventional beam pipelines.
  source=source.replace("#include <minecraft:oit.glsl>","");
 }
 long sc=shaderc_compiler_initialize(), opt=shaderc_compile_options_initialize();
 shaderc_compile_options_set_auto_bind_uniforms(opt,true);
 shaderc_compile_options_set_auto_map_locations(opt,true);
 long r=shaderc_compile_into_spv(sc,source,shaderc_glsl_fragment_shader,"beacon.frag","main",opt);
 if(shaderc_result_get_compilation_status(r)!=0)throw new Exception(shaderc_result_get_error_message(r));
 try(MemoryStack s=MemoryStack.stackPush()){
 PointerBuffer p=s.callocPointer(1);spvc_context_create(p);long ctx=p.get(0);
 IntBuffer spv=shaderc_result_get_bytes(r).order(ByteOrder.nativeOrder()).asIntBuffer();
 spvc_context_parse_spirv(ctx,spv,spv.remaining(),p);long ir=p.get(0);
 spvc_context_create_compiler(ctx,SPVC_BACKEND_MSL,ir,SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,p);long c=p.get(0);
 spvc_compiler_create_compiler_options(c,p);long options=p.get(0);
 spvc_compiler_options_set_uint(options,SPVC_COMPILER_OPTION_MSL_VERSION,30000);
 spvc_compiler_install_compiler_options(c,options);
 if(spvc_compiler_compile(c,p)!=0)throw new Exception(spvc_context_get_last_error_string(ctx));
 Files.writeString(Path.of(args[1]),MemoryUtil.memUTF8(p.get(0)));
 spvc_context_destroy(ctx);
 }
 shaderc_result_release(r);shaderc_compile_options_release(opt);shaderc_compiler_release(sc);
 }
}
