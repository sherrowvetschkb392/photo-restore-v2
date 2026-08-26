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

    int backend_type = -1;
    net->getSessionInfo(session, MNN::Interpreter::BACKENDS, &backend_type);
    if (backend_type != static_cast<int>(MNN_FORWARD_OPENCL)) {
        std::cerr << "ERROR=unexpected_backend backend=" << backend_type
                  << " expected=" << static_cast<int>(MNN_FORWARD_OPENCL) << "\n";
        return 5;
    }

    auto* input = net->getSessionInput(session, nullptr);
    if (!input) {
        std::cerr << "ERROR=input_missing\n";
        return 6;
    }
    net->resizeTensor(input, {1, 3, 64, 64});
    net->resizeSession(session);

    MNN::Tensor input_host(input, MNN::Tensor::CAFFE);
    float* input_data = input_host.host<float>();
    const int count = input_host.elementSize();
    for (int i = 0; i < count; ++i) {
        input_data[i] = static_cast<float>((i % 257) - 128) / 128.0f;
    }
    input->copyFromHostTensor(&input_host);

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

    const float scales[3] = {0.50f, 0.75f, 1.25f};
    const float biases[3] = {0.10f, -0.05f, 0.025f};
    int mismatches = 0;
    float maximum_error = 0.0f;
    const int plane = 64 * 64;
    for (int i = 0; i < count; ++i) {
        const int channel = (i / plane) % 3;
        const float expected = std::max(0.0f, input_data[i] * scales[channel] + biases[channel]);
        const float error = std::fabs(output_data[i] - expected);
        maximum_error = std::max(maximum_error, error);
        if (error > 1.0e-4f) {
            ++mismatches;
        }
    }

    const double elapsed = std::chrono::duration<double>(end - start).count();
    std::cout << "BACKEND=OPENCL\n";
    std::cout << "BACKEND_TYPE=" << backend_type << "\n";
    std::cout << "ELEMENTS=" << count << "\n";
    std::cout << "REPEATS=" << repeats << "\n";
    std::cout << "TOTAL_SECONDS=" << elapsed << "\n";
    std::cout << "PER_INFERENCE_SECONDS=" << (elapsed / repeats) << "\n";
    std::cout << "MISMATCHES=" << mismatches << "\n";
    std::cout << "MAX_ABSOLUTE_ERROR=" << maximum_error << "\n";
    if (mismatches != 0) {
        std::cerr << "ERROR=validation_failed\n";
        return 9;
    }
    std::cout << "RESULT=PASS_MNN_OPENCL_FRAMEWORK_SMOKE\n";
    return 0;
}
