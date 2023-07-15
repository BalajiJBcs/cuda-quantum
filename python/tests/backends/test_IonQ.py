# ============================================================================ #
# Copyright (c) 2022 - 2023 NVIDIA Corporation & Affiliates.                   #
# All rights reserved.                                                         #
#                                                                              #
# This source code and the accompanying materials are made available under     #
# the terms of the Apache License 2.0 which accompanies this distribution.     #
# ============================================================================ #

import cudaq, pytest, os, time
from cudaq import spin
from utils.mock_qpu.ionq import startServer
from multiprocessing import Process

# Define the port for the mock server
port = 62455

pytest.skip(
    "This file produces a segmentation fault on the CI but not locally. See https://github.com/NVIDIA/cuda-quantum/issues/303.",
    allow_module_level=True)


def assert_close(want, got, tolerance=1.0e-5) -> bool:
    return abs(want - got) < tolerance


@pytest.fixture(scope="session", autouse=True)
def startUpMockServer():
    # TODO: Support passing credentials via config file
    os.environ["IONQ_API_KEY"] = "00000000000000000000000000000000"
    credsName = "{}/FakeConfig.config".format(os.environ["HOME"])
    f = open(credsName, "w")
    f.write("key: {}\nrefresh: {}\ntime: 0".format("hello", "rtoken"))
    f.close()

    # Set the targeted QPU
    cudaq.set_target(
        "ionq",
        url="http://localhost:{}".format(port),
        credentials=credsName,
    )

    # Launch the Mock Server
    p = Process(target=startServer, args=(port,))
    p.start()
    time.sleep(1)

    yield "Running the tests."

    # Kill the server, remove the file
    p.terminate()
    os.remove(credsName)


def test_ionq_sample():
    # Create the kernel we'd like to execute on IonQ
    kernel = cudaq.make_kernel()
    qubits = kernel.qalloc(2)
    kernel.h(qubits[0])
    kernel.cx(qubits[0], qubits[1])
    # FIXME CANT HAVE LOOP IN IT YET...
    kernel.mz(qubits[0])
    kernel.mz(qubits[1])
    print(kernel)

    # Run sample synchronously, this is fine
    # here in testing since we are targeting a mock
    # server. In reality you'd probably not want to
    # do this with the remote job queue.
    counts = cudaq.sample(kernel)
    assert len(counts) == 2
    assert "00" in counts
    assert "11" in counts

    # Run sample, but do so asynchronously. This enters
    # the execution job into the remote IonQ job queue.
    future = cudaq.sample_async(kernel)
    # We could go do other work, but since this
    # is a mock server, get the result
    counts = future.get()
    assert len(counts) == 2
    assert "00" in counts
    assert "11" in counts

    # Ok now this is the most likely scenario, launch the
    # job asynchronously, this puts it in the queue, now
    # you can take the future and persist it to file for later.
    future = cudaq.sample_async(kernel)
    print(future)

    # Persist the future to a file (or here a string,
    # could write this string to file for later)
    futureAsString = str(future)

    # Later you can come back and read it in and get
    # the results, which are now present because the job
    # made it through the queue
    futureReadIn = cudaq.AsyncSampleResult(futureAsString)
    counts = futureReadIn.get()
    assert len(counts) == 2
    assert "00" in counts
    assert "11" in counts


def test_ionq_observe():
    # Create the parameterized ansatz
    kernel, theta = cudaq.make_kernel(float)
    qreg = kernel.qalloc(2)
    kernel.x(qreg[0])
    kernel.ry(theta, qreg[1])
    kernel.cx(qreg[1], qreg[0])

    # Define its spin Hamiltonian.
    hamiltonian = (5.907 - 2.1433 * spin.x(0) * spin.x(1) -
                   2.1433 * spin.y(0) * spin.y(1) + 0.21829 * spin.z(0) -
                   6.125 * spin.z(1))

    # Run the observe task on IonQ synchronously
    res = cudaq.observe(kernel, hamiltonian, 0.59)
    want_expectation_value = -1.71
    assert assert_close(want_expectation_value, res.expectation_z(), 1e-2)

    # Launch it asynchronously, enters the job into the queue
    future = cudaq.observe_async(kernel, hamiltonian, 0.59)
    # Retrieve the results (since we're on a mock server)
    res = future.get()
    assert assert_close(want_expectation_value, res.expectation_z(), 1e-2)

    # Launch the job async, job goes in the queue, and
    # we're free to dump the future to file
    future = cudaq.observe_async(kernel, hamiltonian, 0.59)
    print(future)
    futureAsString = str(future)

    # Later you can come back and read it in
    # You must provide the spin_op so we can reconstruct
    # the results from the term job ids.
    futureReadIn = cudaq.AsyncObserveResult(futureAsString, hamiltonian)
    res = futureReadIn.get()
    assert assert_close(want_expectation_value, res.expectation_z(), 1e-2)


# leave for gdb debugging
if __name__ == "__main__":
    loc = os.path.abspath(__file__)
    pytest.main([loc, "-s"])
