#include <MNN/Interpreter.hpp>
#include <MNN/MNNDefine.h>
#include <MNN/Tensor.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: mnn_opencl_smoke MODEL.mnn\n";
        return 2;
    }

    std::shared_ptr<MNN::Interpreter> net(MNN::Interpreter::createFromFile(argv[1]));
    if (!net) {
        std::cerr << "ERROR=createFromFile_failed\n";
        return 3;
    }

    // Keep the OpenCL cache inside the isolated test directory.  Without an
    // explicit path MNN tries to write an empty filename when the session is
    // destroyed, which obscures the actual smoke-test result.
    net->setCacheFile("/tmp/mnn-opencl-smoke.cache");

    MNN::ScheduleConfig config;
    config.type = MNN_FORWARD_OPENCL;
    config.numThread = 4;
    MNN::BackendConfig backend;
    backend.precision = MNN::BackendConfig::Precision_High;
    backend.power = MNN::BackendConfig::Power_High;
    backend.memory = MNN::BackendConfig::Memory_Normal;
    config.backendConfig = &backend;

    auto* session = net->createSession(config);
    if (!session) {
        std::cerr << "ERROR=createSession_failed\n";
        return 4;
    }

    MNN::ScheduleConfig cpu_config;
    cpu_config.type = MNN_FORWARD_CPU;
    cpu_config.numThread = 4;
    auto* cpu_session = net->createSession(cpu_config);
    if (!cpu_session) {
        std::cerr << "ERROR=create_cpu_session_failed\n";
        return 4;
    }

    int backend_type = -1;
    net->getSessionInfo(session, MNN::Interpreter::BACKENDS, &backend_type);
    if (backend_type != static_cast<int>(MNN_FORWARD_OPENCL)) {
        std::cerr << "ERROR=unexpected_backend backend=" << backend_type
                  << " expected=" << static_cast<int>(MNN_FORWARD_OPENCL) << "\n";
        return 5;
    }

    auto* input = net->getSessionInput(session, nullptr);
    auto* cpu_input = net->getSessionInput(cpu_session, nullptr);
    if (!input || !cpu_input) {
        std::cerr << "ERROR=input_missing\n";
        return 6;
    }
    net->resizeTensor(input, {1, 3, 64, 64});
    net->resizeTensor(cpu_input, {1, 3, 64, 64});
    net->resizeSession(session);
    net->resizeSession(cpu_session);

    MNN::Tensor input_host(input, MNN::Tensor::CAFFE);
    MNN::Tensor cpu_input_host(cpu_input, MNN::Tensor::CAFFE);
    float* input_data = input_host.host<float>();
    float* cpu_input_data = cpu_input_host.host<float>();
    const int count = input_host.elementSize();
    for (int i = 0; i < count; ++i) {
        input_data[i] = static_cast<float>((i % 257) - 128) / 128.0f;
        cpu_input_data[i] = input_data[i];
    }
    input->copyFromHostTensor(&input_host);
    cpu_input->copyFromHostTensor(&cpu_input_host);

    if (net->runSession(cpu_session) != MNN::NO_ERROR) {
        std::cerr << "ERROR=cpu_run_failed\n";
        return 7;
    }
    auto* cpu_output = net->getSessionOutput(cpu_session, nullptr);
    if (!cpu_output) {
        std::cerr << "ERROR=cpu_output_missing\n";
        return 8;
    }
    MNN::Tensor cpu_output_host(cpu_output, MNN::Tensor::CAFFE);
    cpu_output->copyToHostTensor(&cpu_output_host);

    const auto start = std::chrono::steady_clock::now();
    constexpr int repeats = 50;
    for (int i = 0; i < repeats; ++i) {
        if (net->runSession(session) != MNN::NO_ERROR) {
            std::cerr << "ERROR=runSession_failed iteration=" << i << "\n";
            return 7;
        }
    }
    const auto end = std::chrono::steady_clock::now();

    auto* output = net->getSessionOutput(session, nullptr);
    if (!output) {
        std::cerr << "ERROR=output_missing\n";
        return 8;
    }
    MNN::Tensor output_host(output, MNN::Tensor::CAFFE);
    output->copyToHostTensor(&output_host);
    const float* output_data = output_host.host<float>();
    const float* reference_data = cpu_output_host.host<float>();
    const int output_count = output_host.elementSize();
    if (!output_data || !reference_data || output_count <= 0 || output_count != cpu_output_host.elementSize()) {
        std::cerr << "ERROR=output_buffer_invalid\n";
        return 8;
    }
    int mismatches = 0;
    float maximum_error = 0.0f;
    int non_finite = 0;
    for (int i = 0; i < output_count; ++i) {
        if (!std::isfinite(output_data[i]) || !std::isfinite(reference_data[i])) {
            ++non_finite;
            continue;
        }
        const float error = std::fabs(output_data[i] - reference_data[i]);
        maximum_error = std::max(maximum_error, error);
        if (error > 1.0e-3f) {
            ++mismatches;
        }
    }

    const double elapsed = std::chrono::duration<double>(end - start).count();
    std::cout << "BACKEND=OPENCL\n";
    std::cout << "BACKEND_TYPE=" << backend_type << "\n";
    std::cout << "ELEMENTS=" << output_count << "\n";
    std::cout << "REPEATS=" << repeats << "\n";
    std::cout << "TOTAL_SECONDS=" << elapsed << "\n";
    std::cout << "PER_INFERENCE_SECONDS=" << (elapsed / repeats) << "\n";
    std::cout << "MISMATCHES=" << mismatches << "\n";
    std::cout << "NON_FINITE=" << non_finite << "\n";
    std::cout << "MAX_ABSOLUTE_ERROR=" << maximum_error << "\n";
    if (mismatches != 0 || non_finite != 0) {
        std::cerr << "ERROR=validation_failed\n";
        return 9;
    }
    std::cout << "RESULT=PASS_MNN_OPENCL_FRAMEWORK_SMOKE\n";
    return 0;
}
