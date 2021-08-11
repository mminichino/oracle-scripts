import setuptools

with open("README.md", "r") as fh:
    long_description = fh.read()

setuptools.setup(
    name="oracle_utils",                    # This is the name of the package
    version="1.0.0",                        # The initial release version
    author="Michael Minichino",             # Full name of the author
    description="Oracle SQLPlus Automation for Database Scripting",
    long_description=long_description,      # Long description read from the the readme file
    long_description_content_type="text/markdown",
    packages=setuptools.find_packages(),    # List of all python modules to be installed
    classifiers=[
        "Programming Language :: Python :: 2",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
    ],                                      # Information to filter the project on PyPi website
    python_requires='>=2.7',                # Minimum version requirement of the package
    py_modules=["oracle_utils"],            # Name of the python package
    package_dir={'':'oracle_utils/src'},    # Directory of the source code of the package
    install_requires=[]                     # Install other dependencies if any
)
