<!-- Based on README.md template by https://github.com/othneildrew/Best-README-Template -->
<a name="readme-top"></a>

<!-- PROJECT SHIELDS -->
<!--
*** I'm using markdown "reference style" links for readability.
*** Reference links are enclosed in brackets [ ] instead of parentheses ( ).
*** See the bottom of this document for the declaration of the reference variables
*** for contributors-url, forks-url, etc. This is an optional, concise syntax you may use.
*** https://www.markdownguide.org/basic-syntax/#reference-style-links
-->
<div align="center">

[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![MIT License][license-shield]][license-url]
[![Workoho][Workoho]][Workoho-url]
</div>


<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/Workoho/AzAuto-Common-Runbook-FW">
    <img src="images/logo.svg" alt="Logo" width="80" height="80">
  </a>

<h3 align="center">Azure Automation Common Runbook Framework</h3>

  <p align="center">
    A complete environment that helps you create, manage, and test your Azure Automation runbooks in a standardized and efficient way.
    <br />
    <a href="https://github.com/Workoho/AzAuto-Common-Runbook-FW/wiki"><strong>Explore the docs »</strong></a>
    <br />

[![Open template in GitHub Codespaces](https://img.shields.io/badge/Open%20in-GitHub%20Codespaces-blue?logo=github)](https://codespaces.new/Workoho/AzAuto-Project.tmpl)
&nbsp;&nbsp;&nbsp;
[![View template online in Visual Studio Code](https://img.shields.io/badge/View%20Online%20in-Visual%20Studio%20Code-blue?logo=visual-studio-code)](https://vscode.dev/github/Workoho/AzAuto-Project.tmpl)
    <br />
    <a href="https://github.com/Workoho/AzAuto-Common-Runbook-FW/issues/new?labels=bug&template=bug-report---.md">Report Bug</a>
    ·
    <a href="https://github.com/Workoho/AzAuto-Common-Runbook-FW/issues/new?labels=enhancement&template=feature-request---.md">Request Feature</a>
  </p>
</div>



<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#built-with">Built With</a></li>
      </ul>
      <ul>
        <li><a href="#1-setup-with-ease">1. Setup with ease</a></li>
      </ul>
      <ul>
        <li><a href="#2-best-practice-standard-runbooks">2. Best practice standard runbooks</a></li>
      </ul>
      <ul>
        <li><a href="#3-runbook-development-made-easy">3. Runbook development made easy</a></li>
      </ul>
      <ul>
        <li><a href="#4-versioning-and-release-management">4. Versioning and release management</a></li>
      </ul>
      <ul>
        <li><a href="#5-development-environment-without-barriers">5. Development environment without barriers</a></li>
      </ul>
      <ul>
        <li><a href="#6-multi-platform-support">6. Multi-platform support</a></li>
      </ul>
      <ul>
        <li><a href="#7-integrate-with-other-systems-in-your-organization">7. Integrate with other systems in your organization</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#usage">Usage</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#maintainers">Maintainers</a></li>
    <li><a href="#projects-using-this-framework">Projects using this framework</a></li>
  </ol>
</details>



<!-- ABOUT THE PROJECT -->
## About The Project

Starting a new Azure Automation project can be very time consuming. After you create an Automation account, you have a blank slate to start writing your PowerShell runbooks. You are wondering how to start developing locally and what to consider now to work around the Azure Automation sandbox limitations and avoid running on a virtual machine with a hybrid worker.

### Quick Summary

**The purpose of the framework:**
The framework is designed to provide a repeatable way to set up and reconfigure an Azure Automation instance, and to enable modular runbook development with common child runbooks.

**The features of the framework:**
The framework supports best practice standard runbooks, local development, versioning and release management, multi-platform compatibility, and integration with other systems.

**The development environment options:**
The framework allows the use of development containers on GitHub Codespaces, Docker, or any remote server to launch a consistent and reliable PowerShell development environment.



### Built With

<div align="center">

[![Azure Automation][AzureAutomation]][AzureAutomation-url]
[![GitHub Codespaces][GitHubCodespaces]][GitHubCodespaces-url]
[![Visual Studio Code][VScode]][VScode-url]
[![PowerShell][PowerShell]][PowerShell-url]

</div>

<p align="right">(<a href="#readme-top">back to top</a>)</p>


--------------------------------------------------------------------------------


### 1. Setup with ease

With this framework, you can easily set up and change your Azure Automation instance. For example, activating managed identities, adding permissions for them in the Microsoft Azure Cloud, the Microsoft Entra directory and enterprise applications in your tenant.

### 2. Best practice standard runbooks

It also provides common child runbooks to start [modular runbook development](https://learn.microsoft.com/en-us/azure/automation/automation-child-runbooks) from day one.

You can start these from your own runbooks by using [inline execution](https://learn.microsoft.com/en-us/azure/automation/automation-child-runbooks#call-a-child-runbook-by-using-inline-execution) to do very basic tasks that you usually want to do the same way in many runbooks. For example, connecting to Azure Cloud, Microsoft Graph API, Exchange Online API, etc. In addition, you probably want to know more about the tenant and the environment you are working in so that you can use this information in your script.

Debugging is also an important part of development and daily operations. The common runbooks provided help you to filter out unnecessary information, e.g. when importing modules. They help you to focus on the actual debugging information that you have included in your own code and not on what PowerShell modules have included for debugging themselves. The output and debugging information from child runbooks is always visible, so you can quickly and easily identify the line of code you may need to correct.

Writing secure automations is also very important because we are often dealing with very sensitive parts of the infrastructure, such as identity management issues and the administration of roles and privileges. This requires additional effort and code and is not the first priority for what you actually need to achieve from a functional perspective. Dedicated common runbooks provide a standard approach to critical security issues that can be easily integrated into your own automations so you can focus on what you want to achieve.

### 3. Runbook development made easy

Developing your runbooks can be annoying because triggering a new job in Azure Automation takes a long time, especially when using the serverless Azure Automation sandbox.

The framework includes common runbooks that make it faster and cheaper to develop locally. They are designed to work with interactive connections to Microsoft services when you are developing locally on your workstation and use managed identities when running as an actual Azure Automation job.

When testing in the Azure Automation Sandbox, a draft version of all your updated runbooks can be easily synchronized with a single command, without interrupting your live runbooks.
Of course, you can also set up a 1-to-1 copy of your production Automation Account for testing and development. Since setting up your runtime environment is just some keystrokes away, this might even be your preferred option.

We also support the new Azure Automation Runtime Environments, which offer you even more flexibility during development and production rollout.

### 4. Versioning and release management

Tracking changes is just as important as communicating those changes to your team to keep your runbooks running. Correct and easy versioning is an essential part of this. It starts with the very first line of code, leads to a testing phase and ends in a production release, so the cycle can start from the beginning. Continuous improvement according to the motto "publish often, publish fast" requires a clear process. This framework is designed to support you on several levels and is fully compatible with [Semantic Versioning 2.0](https://semver.org/).

### 5. Development environment without barriers

Speaking of setting up your development environment: To get things started as quickly as possible, you can use [Development Containers](https://containers.dev/) on either [GitHub Codespaces](https://github.com/features/codespaces), Docker on your workstation, or any remote server to launch a consistent and reliable PowerShell development environment. With GitHub Codespaces, you can even do this in your browser without having to install anything on your local device. Visit [Visual Studio Code docs](https://code.visualstudio.com/docs/devcontainers/containers) to learn more about developing inside a container.

### 6. Multi-platform support

All common runbooks are designed to run on multiple platforms, including Windows PowerShell 5.1 on Windows and modern PowerShell Core on Windows, Linux, and macOS. This provides the most flexibility for developing and maintaining your automation projects.

Due to feature limitations of PowerShell 7 runbooks in Azure Automation, all common runbooks are backward compatible and will use Windows PowerShell 5.1 within the Azure Automation sandbox.

### 7. Integrate with other systems in your organization

The provided template comes with some sample runbooks to demonstrate how you can use the common runbooks and write standardized runbooks that can be easily integrated into your enterprise environment. For example, you can send a job result in JSON format, including important and useful metadata about the job status, to your back-end systems for further processing (e.g., ServiceNow, Tenfold, etc.). The result can either be submitted using a webhook, or by manually polling the PowerShell output stream of the Azure Automation job using a service principal with limited access to your Automation Account.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- GETTING STARTED -->
## Getting Started

This is an example of how you may give instructions on setting up your project locally.
To get a local copy up and running follow these simple example steps.

### Prerequisites

This is an example of how to list things you need to use the software and how to install them.

### Installation

1. Describe Step 1.

2. Describe Step 2.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- USAGE EXAMPLES -->
## Usage

Use this space to show useful examples of how a project can be used. Additional screenshots, code examples and demos work well in this space. You may also link to more resources.

_For more examples, please refer to the [Wiki](https://github.com/Workoho/AzAuto-Common-Runbook-FW/wiki)_.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- CONTRIBUTING -->
## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".
Don't forget to give the project a star! Thanks again!

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- LICENSE -->
## License

Distributed under the MIT License. See `LICENSE.txt` for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- MAINTAINERS -->
## Maintainers

* Julian Pawlowski - [@jpawlowski](https://github.com/jpawlowski)

Project Link: [https://github.com/Workoho/AzAuto-Common-Runbook-FW](https://github.com/Workoho/AzAuto-Common-Runbook-FW)

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- Projects using this framework -->
## Projects using this framework

* [Cloud Administration Tiering Security Model for Microsoft Entra](https://github.com/Workoho/Entra-Tiering-Security-Model)

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
[contributors-shield]: https://img.shields.io/github/contributors/Workoho/AzAuto-Common-Runbook-FW.svg?style=for-the-badge
[contributors-url]: https://github.com/Workoho/AzAuto-Common-Runbook-FW/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/Workoho/AzAuto-Common-Runbook-FW.svg?style=for-the-badge
[forks-url]: https://github.com/Workoho/AzAuto-Common-Runbook-FW/network/members
[stars-shield]: https://img.shields.io/github/stars/Workoho/AzAuto-Common-Runbook-FW.svg?style=for-the-badge
[stars-url]: https://github.com/Workoho/AzAuto-Common-Runbook-FW/stargazers
[issues-shield]: https://img.shields.io/github/issues/Workoho/AzAuto-Common-Runbook-FW.svg?style=for-the-badge
[issues-url]: https://github.com/Workoho/AzAuto-Common-Runbook-FW/issues
[license-shield]: https://img.shields.io/github/license/Workoho/AzAuto-Common-Runbook-FW.svg?style=for-the-badge
[license-url]: https://github.com/Workoho/AzAuto-Common-Runbook-FW/blob/master/LICENSE.txt
[AzureAutomation]: https://img.shields.io/badge/Azure_Automation-1F4386?style=for-the-badge&logo=microsoftazure&logoColor=white
[AzureAutomation-url]: https://learn.microsoft.com/azure/automation/
[GitHubCodespaces]: https://img.shields.io/badge/GitHub_Codespaces-09091E?style=for-the-badge&logo=github&logoColor=white
[GitHubCodespaces-url]: https://github.com/features/codespaces
[VScode]: https://img.shields.io/badge/Visual_Studio_Code-2C2C32?style=for-the-badge&logo=visualstudiocode&logoColor=3063B4
[VScode-url]: https://code.visualstudio.com/
[PowerShell]: https://img.shields.io/badge/PowerShell-2C3C57?style=for-the-badge&logo=powershell&logoColor=white
[PowerShell-url]: https://microsoft.com/PowerShell
[Workoho]: https://img.shields.io/badge/Workoho.com-00B3CE?style=for-the-badge&logo=data:image/svg%2bxml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiIHN0YW5kYWxvbmU9Im5vIj8+CjwhRE9DVFlQRSBzdmcgUFVCTElDICItLy9XM0MvL0RURCBTVkcgMS4xLy9FTiIgImh0dHA6Ly93d3cudzMub3JnL0dyYXBoaWNzL1NWRy8xLjEvRFREL3N2ZzExLmR0ZCI+Cjxzdmcgd2lkdGg9IjEwMCUiIGhlaWdodD0iMTAwJSIgdmlld0JveD0iMCAwIDEzNDggOTEzIiB2ZXJzaW9uPSIxLjEiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgeG1sbnM6eGxpbms9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkveGxpbmsiIHhtbDpzcGFjZT0icHJlc2VydmUiIHhtbG5zOnNlcmlmPSJodHRwOi8vd3d3LnNlcmlmLmNvbS8iIHN0eWxlPSJmaWxsLXJ1bGU6ZXZlbm9kZDtjbGlwLXJ1bGU6ZXZlbm9kZDtzdHJva2UtbGluZWpvaW46cm91bmQ7c3Ryb2tlLW1pdGVybGltaXQ6MjsiPgogICAgPGcgdHJhbnNmb3JtPSJtYXRyaXgoNC4wNzQ3OCwwLDAsMy45NjAzOCwtNzQzMS4xNSwtNDYzNC44OCkiPgogICAgICAgIDxnPgogICAgICAgICAgICA8ZyB0cmFuc2Zvcm09Im1hdHJpeCg4LjY2MzI2ZS0xOCwwLjE0MTQ4MiwtMC4xNDE0ODIsOC42NjMyNmUtMTgsNDA1Ny43MiwtNDI5LjM1KSI+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMTI3MjYsMTM0NTIuN0wxMjc2Mi4zLDEzNDUyLjdMMTI5MzUuOCwxNDE2Ni40TDEyODk2LjEsMTQxNjYuNEwxMjcyNi44LDEzOTQ2LjRMMTI1NDMsMTM4OTAuM0wxMjcyNiwxMzQ1Mi43WiIvPgogICAgICAgICAgICA8L2c+CiAgICAgICAgICAgIDxnIHRyYW5zZm9ybT0ibWF0cml4KDAuMDg0NDk1NCwwLDAsMC4wODQ0OTU0LDE5NDEuOCwxMTA4LjU1KSI+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMTUxOC42MSwyOTk1LjQzTDExOTEuNDksMjk5NS40M0wxMDIyLjcsMzExMS40NkwxMDIyLjcsMzIxNS4wMUwxMjk3LjcsMzIxNS4wMUwxNTE4LjYxLDMwNjIuMDVMMTUxOC42MSwyOTk1LjQzWiIvPgogICAgICAgICAgICA8L2c+CiAgICAgICAgICAgIDxnIHRyYW5zZm9ybT0ibWF0cml4KDAuMDg0NDk1NCwwLDAsMC4wODQ0OTU0LDE4MTQuMDMsMTEwOC41NSkiPgogICAgICAgICAgICAgICAgPHBhdGggZD0iTTE5MTMuNDIsMjk5NS40M0wxMTkxLjQ5LDI5OTUuNDNMMTAyMi43LDMxMTEuNDZMMTAyMi43LDMyMTUuMDFMMTY5Mi41MiwzMjE1LjAxTDE5MTMuNDIsMzA2Mi4wNUwxOTEzLjQyLDI5OTUuNDNaIi8+CiAgICAgICAgICAgIDwvZz4KICAgICAgICA8L2c+CiAgICAgICAgPGc+CiAgICAgICAgICAgIDxnIHRyYW5zZm9ybT0ibWF0cml4KDAuMDg0NDk1NCwwLDAsMC4wODQ0OTU0LDE3MzEuODUsOTE3LjIxKSI+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMTkxMy40MiwyOTk1LjQzTDEyNTUuNzQsMjk5NS40M0wxMDg2Ljk0LDMxMTEuNDZMMTA4Ni45NCwzMjE1LjAxTDE2OTIuNTIsMzIxNS4wMUwxOTEzLjQyLDMwNjIuMDVMMTkxMy40MiwyOTk1LjQzWiIgc3R5bGU9ImZpbGw6d2hpdGU7Ii8+CiAgICAgICAgICAgIDwvZz4KICAgICAgICAgICAgPGcgdHJhbnNmb3JtPSJtYXRyaXgoMC45Mzc1NTgsMCwwLDAuOTM3NTU4LC00NzYwLjU0LC00MDgzLjg4KSI+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNNzIwMi4xMiw1NjcxLjYzTDcyMDIuMTIsNTY4MC45TDcxNjMuNiw1NzIzLjM0TDcyNDAuODksNTgxOC43Mkw3MjQwLjg5LDU4MjcuOTlMNzIxMy40Myw1ODI3Ljk5TDcxMzkuNTMsNTczNy4wN0w3MTA0LjYxLDU3MzcuMDdMNzEwNC42MSw1ODI3Ljk5TDcwNzcuMzIsNTgyNy45OUw3MDc3LjMyLDU2MjMuOTFMNzEwNC42MSw1NjIzLjkxTDcxMDQuNjEsNTcwOS42MUw3MTM5LjUzLDU3MDkuNjFMNzE3NC42Niw1NjcxLjYzTDcyMDIuMTIsNTY3MS42M1oiIHN0eWxlPSJmaWxsOndoaXRlO2ZpbGwtcnVsZTpub256ZXJvOyIvPgogICAgICAgICAgICA8L2c+CiAgICAgICAgPC9nPgogICAgPC9nPgo8L3N2Zz4K
[Workoho-url]: https://workoho.com/
