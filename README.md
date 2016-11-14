The tensorflow-ocaml project provides some [OCaml](http://ocaml.org) bindings for [TensorFlow](http://tensorflow.org).

These bindings are in an early stage of their development. Some operators are not supported and the API is likely to change in the future. That being said they already contain the necessary to train a convolution network using various optimizers.

## Installation

The easiest way is probably to use opam.

```bash
opam install tensorflow
```

After that you have to get/build the TensorFlow library `libtensorflow-0.10.so`. The opam packages starting from version 0.0.6 use TensorFlow release 0.10, the current tip uses release 0.11 (for which you need to build `libtensorflow-0.11.so`. There are two possibilities to obtain it:

* You can build it from source by following these steps:
    1. [Install the Bazel build system](http://bazel.io/docs/install.html)
    1. Clone the TensorFlow repo `git clone --recurse-submodules -b r0.10 https://github.com/tensorflow/tensorflow`
    1. In `tensorflow` run `./configure` then `bazel build -c opt tensorflow:libtensorflow.so`. Note: you first have to edit tensorflow/BUILD to include `"//tensorflow/c:c_api"` in the deps section of libtensorflow.so.
       - In order to build with GPU support, CUDA needs to be installed and specified during `./configure`, and use `bazel build -c opt --config=cuda tensorflow:libtensorflow.so` to build.
* You can download a prebuilt x86-64 linux binaries, [libtensorflow-0.10.so](https://github.com/LaurentMazare/tensorflow-ocaml/releases/download/0.0.5/libtensorflow-0.10.so) or [libtensorflow-0.11.so](https://github.com/LaurentMazare/tensorflow-ocaml/releases/download/0.0.6/libtensorflow-0.11.so).

Adjust your LD_LIBRARY_PATH to include the directory in which you've put `libtensorflow-0.10.so` and finally download a [very simple example](https://github.com/LaurentMazare/tensorflow-ocaml/tree/master/examples/basics/forty_two.ml) and compile it with the following command:
```bash
ocamlbuild forty_two.native -package ctypes -package ctypes.foreign -package core_kernel -package tensorflow -cflags -w,-40
```

Enjoy!

## Examples

Tensorflow-ocaml includes two different APIs to write graphs.

### Using the Graph API

The graph API is very close to the original TensorFlow API.
* Some MNIST based tutorials are available in the [examples directory](https://github.com/LaurentMazare/tensorflow-ocaml/tree/master/examples/mnist).
* `examples/load/load.ml` contains a simple example where the TensorFlow graph is loaded from a file (this graph has been generated by `examples/load.py`).
* `examples/basics` contains some curve fitting examples. You will need gnuplot to be installed via opam to run the gnuplot versions.

### Using the FNN API

The FNN API is a layer based API to easily build neural-networks. A linear classifier could be defined and trained in a couple lines:

```ocaml
  let input, input_id = Fnn.input ~shape:(D1 image_dim) in
  let model =
    Fnn.dense label_count input
    |> Fnn.softmax
    |> Fnn.Model.create Float
  in
  Fnn.Model.fit model
    ~loss:(Fnn.Loss.cross_entropy `mean)
    ~optimizer:(Fnn.Optimizer.gradient_descent ~learning_rate:8.)
    ~epochs
    ~input_id
    ~xs:train_images
    ~ys:train_labels;
```

There are also some MNIST based [examples](https://github.com/LaurentMazare/tensorflow-ocaml/tree/master/examples/fnn).

### Character level RNN

A simplified version of [char-rnn](https://github.com/karpathy/char-rnn) can also be found in the [examples directory](https://github.com/LaurentMazare/tensorflow-ocaml/blob/master/examples/char_rnn/char_rnn.ml). This ocaml port uses two LSTM layers. You can compile it with the following command:
```bash
ocamlbuild examples/char_rnn/char_rnn.native
```
Then you can train it on some text file, e.g. a [Shakespeare corpus](https://github.com/karpathy/char-rnn/blob/master/data/tinyshakespeare/input.txt).
```bash
./char_rnn.native train --train-file path/to/input.txt
```
During the training the current LSTM network will be dumped every 500 epochs in a .cpkt file. This file can later be used to generate new contents in the style of the training file.
```bash
./char_rnn.native sample --train-file path/to/input.txt
```

## Dependencies

* [ocaml-ctypes](https://github.com/ocamllabs/ocaml-ctypes) is used for the C bindings.
* [Core_kernel](https://github.com/janestreet/core_kernel) is only necessary when generating the graph from OCaml, the wrapper itself does not need it.
* The code in the piqi directory comes from the [Piqi project](http://piqi.org). There is no need to install piqi though.
* [Cmdliner](https://github.com/dbuenzli/cmdliner) is used for command line interfaces.
* [Gnuplot-ocaml](https://bitbucket.org/ogu/gnuplot-ocaml) is an optional dependency used by a couple examples.
