use anyhow::Result;
use torch_build::{CppExtension, CudaExtension};

static CPP_SOURCE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/csrc/nms_cpu.cpp");
static CUDA_SOURCE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/csrc/nms_cuda.cu");

fn main() -> Result<()> {
    // re-compile if C++/CUDA source changed
    println!("cargo:rerun-if-changed={}", CPP_SOURCE);
    println!("cargo:rerun-if-changed={}", CUDA_SOURCE);

    // compile nms_cpu.cpp
    {
        let mut build = cc::Build::new();
        let mut cpp_ext = CppExtension::new();
        cpp_ext
            .use_cuda_api(true)
            .link_python(true)
            .source(CPP_SOURCE);
        cpp_ext.configure(&mut build)?;
        build.try_compile("nms_cpu")?;
        cpp_ext.link()?;
    }

    // compile nms_cuda.cu
    {
        let mut build = cc::Build::new();
        let mut cuda_ext = CudaExtension::new();
        cuda_ext.link_python(false).source(CUDA_SOURCE);
        cuda_ext.configure(&mut build)?;
        build.try_compile("nms_cuda")?;
        cuda_ext.link()?;
    }

    Ok(())
}
