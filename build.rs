use anyhow::Result;

static CPP_SOURCE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/csrc/nms_cpu.cpp");
static CUDA_SOURCE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/csrc/nms_cuda.cu");

fn main() -> Result<()> {
    let mut cargo_commands = vec![];

    // compile nms_cpu.cpp
    let mut build = cc::Build::new();
    torch_build::build_cpp(
        &mut build,
        true,
        false,
        Some(&mut cargo_commands),
        [CPP_SOURCE],
    )?;
    build.try_compile("nms_cpu")?;

    // compile nms_cuda.cu
    let mut build = cc::Build::new();
    torch_build::build_cuda(&mut build, false, Some(&mut cargo_commands), [CUDA_SOURCE])?;
    build.try_compile("nms_cuda")?;

    // re-compile if C++/CUDA source changed
    println!("cargo:rerun-if-changed={}", CPP_SOURCE);
    println!("cargo:rerun-if-changed={}", CUDA_SOURCE);
    cargo_commands.iter().for_each(|command| {
        println!("{}", command);
    });

    Ok(())
}
