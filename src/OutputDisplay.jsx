import React from 'react';

export default class OutputDisplay extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      text: '',
    };
  }

  static contextTypes = {
    workerEmitter: React.PropTypes.any,
  };

  componentDidMount() {
    this.context.workerEmitter.on('clearOutput', () => {
      this.setState({ text: '' });
    });
    this.context.workerEmitter.on('output', data => {
      this.setState(state => ({ text: state.text + data }));
    });
  }

  render() {
    return (
      <div
        style={{ background: 'rgb(38, 50, 56)', whiteSpace: 'pre', fontFamily: 'monospace', minWidth: '100%', height: '100%', position: 'absolute', paddingLeft: '4px', color: '#dcdccc' }}
      >
        {this.state.text}
      </div>
    );
  }
}
